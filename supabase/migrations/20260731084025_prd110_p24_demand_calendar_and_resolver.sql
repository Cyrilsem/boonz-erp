-- PRD-110 P2.4 · Demand multipliers.
-- BUILD SPEC: demand_calendar(week, machine_class|machine_id NULL, factor, source
--             enum(macro_kpi,event,dow)); effective_velocity = velocity_instock x PIfactors
--             clamped 0.5-2.5.
-- Proven by golden fixture 31 (baselined RED at 0/35 immediately before this migration).
--
-- Cody review (leg 48) required and this migration carries: tg_audit_demand_calendar
-- (Article 8), tg_demand_calendar_append_only (Article 7), ON DELETE RESTRICT rather than
-- CASCADE (audit-bearing history is never silently erased), and the loader writing THROUGH
-- the canonical writer rather than INSERTing directly (Article 1).
--
-- SHIPS WITH AN EMPTY CALENDAR ON PURPOSE. With zero active rows the resolver is exactly 1.0
-- for every machine, so v3 quantities do not move until CS authors a factor. Fixture 31 seq 5
-- pins that, and is the assertion that deliberately flips on the first authored row.

-- ---------------------------------------------------------------- 1. clamp parameters
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS demand_factor_clamp_min numeric(6,4) NOT NULL DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS demand_factor_clamp_max numeric(6,4) NOT NULL DEFAULT 2.5;

COMMENT ON COLUMN public.refill_policy_params.demand_factor_clamp_min IS
  'PRD-110 P2.4. Floor for the PRODUCT of demand factors (not for velocity itself). CS retunes by UPDATE, no migration.';
COMMENT ON COLUMN public.refill_policy_params.demand_factor_clamp_max IS
  'PRD-110 P2.4. Ceiling for the PRODUCT of demand factors. BUILD SPEC default 2.5.';

-- ---------------------------------------------------------------- 2. the calendar
CREATE TABLE IF NOT EXISTS public.demand_calendar (
  demand_calendar_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- WHICH KIND of factor. Each source carries its own temporal shape (see chk_shape).
  source        text NOT NULL CHECK (source IN ('macro_kpi','event','dow')),
  -- macro_kpi shape: an ISO year+week pair.
  iso_year      integer,
  iso_week      integer,
  -- dow shape: a recurring day of week, 0=Sunday, matching EXTRACT(DOW).
  dow           smallint,
  -- event shape: an inclusive date window.
  valid_from    date,
  valid_to      date,
  -- SCOPE. At most one of these; both NULL means fleet-wide. Enforced by chk_scope.
  -- RESTRICT, not CASCADE: machines are repurposed, never deleted, and this row is audited.
  machine_id    uuid REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  machine_class text CHECK (machine_class IN ('backup','busy','standard')),
  factor        numeric(6,4) NOT NULL CHECK (factor > 0 AND factor <= 10),
  note          text NOT NULL,
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','superseded')),
  superseded_at timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  -- NULL is the discriminator here BY DESIGN (the documented exception to Dara's D2):
  -- exactly one temporal shape may be populated, and it must match the source.
  CONSTRAINT chk_demand_calendar_shape CHECK (
       (source = 'macro_kpi' AND iso_year IS NOT NULL AND iso_week BETWEEN 1 AND 53
                             AND dow IS NULL AND valid_from IS NULL AND valid_to IS NULL)
    OR (source = 'dow'       AND dow BETWEEN 0 AND 6
                             AND iso_year IS NULL AND iso_week IS NULL
                             AND valid_from IS NULL AND valid_to IS NULL)
    OR (source = 'event'     AND valid_from IS NOT NULL AND valid_to IS NOT NULL
                             AND valid_to >= valid_from
                             AND iso_year IS NULL AND iso_week IS NULL AND dow IS NULL)
  ),
  CONSTRAINT chk_demand_calendar_scope CHECK (
    NOT (machine_id IS NOT NULL AND machine_class IS NOT NULL)
  ),
  CONSTRAINT chk_demand_calendar_superseded CHECK (
    (status = 'superseded') = (superseded_at IS NOT NULL)
  )
);

COMMENT ON TABLE public.demand_calendar IS
  'PRD-110 P2.4. Authored demand multipliers. Append-only with supersede. Article 14: this is authored state (CS factors + loader output), NOT a materialization of anything a view could compute, so no ADR is required. Resolution: most specific scope wins WITHIN a source; sources multiply; the product is clamped by refill_policy_params.demand_factor_clamp_min/max. ⛔ Do NOT confuse this most-specific rule with the ANY-SCOPE rule that governs product_sourcing (S-53) - they are different questions and the answers are deliberately opposite.';

-- One ACTIVE row per (source, temporal key, scope). NULLS NOT DISTINCT (PG15+) makes the
-- partially-NULL temporal shapes compare as equal rather than as always-distinct.
CREATE UNIQUE INDEX IF NOT EXISTS ux_demand_calendar_active
  ON public.demand_calendar (source, iso_year, iso_week, dow, valid_from, valid_to,
                             machine_id, machine_class)
  NULLS NOT DISTINCT
  WHERE status = 'active';

-- Serves the resolver's only access path: active rows, filtered by source.
CREATE INDEX IF NOT EXISTS ix_demand_calendar_active_source
  ON public.demand_calendar (source) WHERE status = 'active';

-- Article 2 + Article 3: RLS on, SELECT only. No INSERT/UPDATE/DELETE policy exists, so the
-- only write path is a SECURITY DEFINER RPC (which bypasses RLS as owner).
ALTER TABLE public.demand_calendar ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='demand_calendar'
                    AND policyname='demand_calendar_select') THEN
    CREATE POLICY demand_calendar_select ON public.demand_calendar
      FOR SELECT TO authenticated USING (true);
  END IF;
END $$;

-- Article 7: append-only. Mirrors tg_product_sourcing_append_only exactly.
CREATE OR REPLACE FUNCTION public.tg_demand_calendar_append_only()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'demand_calendar is append-only: DELETE refused (demand_calendar_id %). Supersede instead.',
      OLD.demand_calendar_id;
  END IF;

  -- The ONLY legal UPDATE is the supersede pair.
  IF NEW.demand_calendar_id IS DISTINCT FROM OLD.demand_calendar_id
  OR NEW.source             IS DISTINCT FROM OLD.source
  OR NEW.iso_year           IS DISTINCT FROM OLD.iso_year
  OR NEW.iso_week           IS DISTINCT FROM OLD.iso_week
  OR NEW.dow                IS DISTINCT FROM OLD.dow
  OR NEW.valid_from         IS DISTINCT FROM OLD.valid_from
  OR NEW.valid_to           IS DISTINCT FROM OLD.valid_to
  OR NEW.machine_id         IS DISTINCT FROM OLD.machine_id
  OR NEW.machine_class      IS DISTINCT FROM OLD.machine_class
  OR NEW.factor             IS DISTINCT FROM OLD.factor
  OR NEW.note               IS DISTINCT FROM OLD.note
  OR NEW.created_at         IS DISTINCT FROM OLD.created_at
  OR NEW.created_by         IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'demand_calendar is append-only: only (status, superseded_at) may be updated '
                    '(the supersede). Attempted change on demand_calendar_id %.', OLD.demand_calendar_id;
  END IF;

  IF OLD.status = 'superseded' THEN
    RAISE EXCEPTION 'demand_calendar: demand_calendar_id % is already superseded and is immutable.',
      OLD.demand_calendar_id;
  END IF;

  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS tg_demand_calendar_append_only ON public.demand_calendar;
CREATE TRIGGER tg_demand_calendar_append_only
  BEFORE UPDATE OR DELETE ON public.demand_calendar
  FOR EACH ROW EXECUTE FUNCTION public.tg_demand_calendar_append_only();

-- Article 8: universal audit, same shape as every other PRD-110 table.
DROP TRIGGER IF EXISTS tg_audit_demand_calendar ON public.demand_calendar;
CREATE TRIGGER tg_audit_demand_calendar
  AFTER INSERT OR UPDATE OR DELETE ON public.demand_calendar
  FOR EACH ROW EXECUTE FUNCTION audit_log_write('demand_calendar_id');

-- ---------------------------------------------------------------- 3. the resolver (read-only)
CREATE OR REPLACE FUNCTION public.resolve_demand_multiplier_v3(
  p_machine_id uuid,
  p_plan_date  date
)
RETURNS TABLE (factor numeric, factor_raw numeric, n_factors integer, clamped boolean, provenance jsonb)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
  WITH prm AS (
    SELECT demand_factor_clamp_min AS mn, demand_factor_clamp_max AS mx
      FROM public.refill_policy_params LIMIT 1
  ), cls AS (
    SELECT machine_class FROM public.machine_service_policy WHERE machine_id = p_machine_id
  ), app AS (
    SELECT dc.demand_calendar_id, dc.source, dc.factor, dc.note, dc.created_at,
           CASE WHEN dc.machine_id IS NOT NULL THEN 1
                WHEN dc.machine_class IS NOT NULL THEN 2 ELSE 3 END AS sp,
           CASE WHEN dc.machine_id IS NOT NULL THEN 'machine'
                WHEN dc.machine_class IS NOT NULL THEN 'class' ELSE 'fleet' END AS scope
      FROM public.demand_calendar dc
      LEFT JOIN cls ON true
     WHERE dc.status = 'active'
       AND (dc.machine_id = p_machine_id
            OR (dc.machine_id IS NULL AND dc.machine_class = cls.machine_class)
            OR (dc.machine_id IS NULL AND dc.machine_class IS NULL))
       AND (CASE dc.source
              WHEN 'macro_kpi' THEN dc.iso_year = EXTRACT(ISOYEAR FROM p_plan_date)::int
                                AND dc.iso_week = EXTRACT(WEEK    FROM p_plan_date)::int
              WHEN 'dow'       THEN dc.dow      = EXTRACT(DOW     FROM p_plan_date)::int
              WHEN 'event'     THEN p_plan_date BETWEEN dc.valid_from AND dc.valid_to
            END)
  ), win AS (
    -- Most specific scope wins WITHIN a source. Deterministic tie-break: stronger factor,
    -- then newest. Overlapping event windows are possible, so this ordering is load-bearing.
    SELECT DISTINCT ON (source) * FROM app
     ORDER BY source, sp, factor DESC, created_at DESC
  ), agg AS (
    SELECT COALESCE((SELECT w.factor FROM win w WHERE w.source='macro_kpi'), 1)
         * COALESCE((SELECT w.factor FROM win w WHERE w.source='event'),     1)
         * COALESCE((SELECT w.factor FROM win w WHERE w.source='dow'),       1) AS raw,
           (SELECT count(*) FROM win) AS n,
           (SELECT jsonb_agg(jsonb_build_object(
                     'demand_calendar_id', w.demand_calendar_id, 'source', w.source,
                     'scope', w.scope, 'factor', w.factor, 'note', w.note) ORDER BY w.source)
              FROM win w) AS prov
  )
  SELECT round(LEAST(GREATEST(a.raw, p.mn), p.mx), 4) AS factor,
         round(a.raw, 4)                              AS factor_raw,
         a.n::int                                     AS n_factors,
         (a.raw < p.mn OR a.raw > p.mx)               AS clamped,
         COALESCE(a.prov, '[]'::jsonb)                AS provenance
    FROM agg a CROSS JOIN prm p;
$fn$;

COMMENT ON FUNCTION public.resolve_demand_multiplier_v3(uuid,date) IS
  'PRD-110 P2.4 canonical demand-multiplier resolver. SECURITY INVOKER (read-only). Returns the clamped product, the raw product, the contributing-row count, whether the clamp bound, and provenance naming every contributing row (LAW 5). Empty calendar => exactly 1.0. Proven by golden fixture 31.';

GRANT EXECUTE ON FUNCTION public.resolve_demand_multiplier_v3(uuid,date) TO authenticated, service_role;

-- ---------------------------------------------------------------- 4. the canonical writer
CREATE OR REPLACE FUNCTION public.set_demand_factor_v3(
  p_source        text,
  p_iso_year      integer,
  p_iso_week      integer,
  p_dow           smallint,
  p_valid_from    date,
  p_valid_to      date,
  p_machine_id    uuid,
  p_machine_class text,
  p_factor        numeric,
  p_note          text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_actor   uuid := (SELECT auth.uid());
  v_role    text;
  v_old     uuid;
  v_new     uuid;
  v_changed boolean := false;
BEGIN
  -- Article 4: role validation via the user_profiles join. Never auth.jwt().
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_actor;
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'set_demand_factor_v3: role % may not author demand factors', COALESCE(v_role,'<none>');
  END IF;

  -- Article 4: input validation. The table CHECKs are the backstop, not the first line.
  IF p_source IS NULL OR p_source NOT IN ('macro_kpi','event','dow') THEN
    RAISE EXCEPTION 'set_demand_factor_v3: source must be macro_kpi | event | dow (got %)', p_source;
  END IF;
  IF p_factor IS NULL OR p_factor <= 0 OR p_factor > 10 THEN
    RAISE EXCEPTION 'set_demand_factor_v3: factor must be in (0, 10] (got %)', p_factor;
  END IF;
  IF p_note IS NULL OR length(btrim(p_note)) < 10 THEN
    RAISE EXCEPTION 'set_demand_factor_v3: note is mandatory and must be at least 10 characters';
  END IF;
  IF p_machine_id IS NOT NULL AND p_machine_class IS NOT NULL THEN
    RAISE EXCEPTION 'set_demand_factor_v3: give machine_id OR machine_class OR neither, never both';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_demand_factor_v3', true);

  -- Supersede the incumbent on this exact key, if any.
  SELECT demand_calendar_id INTO v_old
    FROM public.demand_calendar
   WHERE status = 'active'
     AND source            IS NOT DISTINCT FROM p_source
     AND iso_year          IS NOT DISTINCT FROM p_iso_year
     AND iso_week          IS NOT DISTINCT FROM p_iso_week
     AND dow               IS NOT DISTINCT FROM p_dow
     AND valid_from        IS NOT DISTINCT FROM p_valid_from
     AND valid_to          IS NOT DISTINCT FROM p_valid_to
     AND machine_id        IS NOT DISTINCT FROM p_machine_id
     AND machine_class     IS NOT DISTINCT FROM p_machine_class
   FOR UPDATE;

  IF v_old IS NOT NULL THEN
    -- A no-op restatement supersedes nothing: keep history honest.
    IF EXISTS (SELECT 1 FROM public.demand_calendar
                WHERE demand_calendar_id = v_old AND factor = p_factor) THEN
      RETURN jsonb_build_object('changed', false, 'reason', 'identical factor already active',
                                'demand_calendar_id', v_old);
    END IF;
    UPDATE public.demand_calendar
       SET status = 'superseded', superseded_at = now()
     WHERE demand_calendar_id = v_old;
    v_changed := true;
  END IF;

  INSERT INTO public.demand_calendar
    (source, iso_year, iso_week, dow, valid_from, valid_to,
     machine_id, machine_class, factor, note, created_by)
  VALUES
    (p_source, p_iso_year, p_iso_week, p_dow, p_valid_from, p_valid_to,
     p_machine_id, p_machine_class, p_factor, p_note, v_actor)
  RETURNING demand_calendar_id INTO v_new;

  RETURN jsonb_build_object(
    'changed', true, 'superseded', v_old, 'demand_calendar_id', v_new,
    'source', p_source, 'factor', p_factor,
    'scope', CASE WHEN p_machine_id IS NOT NULL THEN 'machine'
                  WHEN p_machine_class IS NOT NULL THEN 'class' ELSE 'fleet' END);
END $fn$;

COMMENT ON FUNCTION public.set_demand_factor_v3 IS
  'PRD-110 P2.4. THE canonical writer for demand_calendar (Article 1). Append-only supersede: never UPDATEs a factor, never DELETEs. Role-gated to operator_admin/superadmin/manager.';

REVOKE ALL ON FUNCTION public.set_demand_factor_v3(text,integer,integer,smallint,date,date,uuid,text,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_demand_factor_v3(text,integer,integer,smallint,date,date,uuid,text,numeric,text) TO authenticated, service_role;

-- ---------------------------------------------------------------- 5. the DOW auto-loader
-- S-02: context-intelligence is absent, so the 'event' leg has no auto-loader and is written
-- by RPC only. The macro_kpi leg has no CS-side source table live either (parked). The DOW
-- leg IS derivable from sales history, so it is the one that ships with a loader.
CREATE OR REPLACE FUNCTION public.load_dow_profile_v3(p_lookback_days integer DEFAULT 90)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_role     text;
  v_min_obs  integer := 4;      -- a DOW needs >= 4 observed dates before it earns a factor
  v_rec      record;
  v_out      jsonb := '[]'::jsonb;
  v_n        integer := 0;
  v_thin     integer;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = (SELECT auth.uid());
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'load_dow_profile_v3: role % may not load the DOW profile', COALESCE(v_role,'<none>');
  END IF;
  IF p_lookback_days IS NULL OR p_lookback_days < 28 THEN
    RAISE EXCEPTION 'load_dow_profile_v3: lookback must be at least 28 days (got %)', p_lookback_days;
  END IF;

  CREATE TEMP TABLE _dow_prof ON COMMIT DROP AS
  WITH d AS (
    -- Reads the CANONICAL resolved-sales object (Article 16), never sales_lines directly.
    SELECT s.transaction_date::date AS dt, SUM(s.qty) AS q
      FROM public.v_sales_history_resolved s
     WHERE s.delivery_status = ANY (ARRAY['Success','Successful'])
       AND s.transaction_date::date >= CURRENT_DATE - p_lookback_days
       AND s.transaction_date::date <  CURRENT_DATE
     GROUP BY 1
  ), per_dow AS (
    SELECT EXTRACT(DOW FROM dt)::smallint AS dow, avg(q) AS mean_q, count(*) AS n_obs
      FROM d GROUP BY 1
  )
  SELECT dow, mean_q, n_obs,
         mean_q / NULLIF(avg(mean_q) OVER (), 0) AS factor
    FROM per_dow;

  -- LAW 5: never silently produce nothing. A thin week is reported, not swallowed.
  SELECT count(*) INTO v_thin FROM _dow_prof WHERE n_obs < v_min_obs OR factor IS NULL;
  IF (SELECT count(*) FROM _dow_prof) < 7 OR v_thin > 0 THEN
    RAISE EXCEPTION 'load_dow_profile_v3: insufficient history — % of 7 days present, % below the % observation floor',
      (SELECT count(*) FROM _dow_prof), v_thin, v_min_obs;
  END IF;

  -- Article 1: write THROUGH the canonical writer, never INSERT here.
  FOR v_rec IN SELECT * FROM _dow_prof ORDER BY dow LOOP
    PERFORM public.set_demand_factor_v3(
      'dow', NULL, NULL, v_rec.dow, NULL, NULL, NULL, NULL,
      round(LEAST(GREATEST(v_rec.factor, 0.1), 10.0), 4),
      format('load_dow_profile_v3: %s-day DOW profile, dow=%s, mean %.2f u/day over %s days',
             p_lookback_days, v_rec.dow, v_rec.mean_q, v_rec.n_obs));
    v_n := v_n + 1;
    v_out := v_out || jsonb_build_object('dow', v_rec.dow, 'factor', round(v_rec.factor,4),
                                         'n_obs', v_rec.n_obs);
  END LOOP;

  RETURN jsonb_build_object('loaded', v_n, 'lookback_days', p_lookback_days, 'profile', v_out);
END $fn$;

COMMENT ON FUNCTION public.load_dow_profile_v3(integer) IS
  'PRD-110 P2.4. Derives the fleet day-of-week demand profile from v_sales_history_resolved (canonical, Article 16), normalised so the mean across the 7 days is 1.0, and writes it through set_demand_factor_v3 (Article 1). NOT invoked by this migration: P2.4 ships with an empty calendar so v3 quantities do not move until CS authors factors.';

REVOKE ALL ON FUNCTION public.load_dow_profile_v3(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.load_dow_profile_v3(integer) TO authenticated, service_role;
