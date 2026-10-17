-- PRD-142a Phase 1, item 3.1: machine_eras and the era sync job.
--
-- An era is one continuous identity of a physical machine at one venue.
-- Strategic KPIs default to the current era (era_end IS NULL).
--
-- Rule (spec 3.1, defaults logged in docs/prds/PRD-142-log.md):
--   boundary = COALESCE(relaunched_at (Dubai date), repurposed_at)
--   With a boundary: current era starts at the boundary; if sales exist
--     before it, one closed prior era runs first sale .. boundary - 1,
--     venue_label = previous_location.
--   Without one: one era from LEAST(installation_date, first sale).
--   Not live (include_in_refill false and no sale in 30 days): one closed
--     era first sale .. last sale, source 'archived'.
--   VOX: PRD-138 era definitions live in a function (vox_machine_eras), not
--     a table or view, so the same rule applies to VOX (spec 3.1 fallback).
-- WH machines (venue_group 'WH' or official_name starting WH) never get eras.

CREATE TABLE public.machine_eras (
  era_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id  uuid NOT NULL REFERENCES public.machines(machine_id),
  venue_label text,
  era_start   date NOT NULL,
  era_end     date,
  source      text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (era_end IS NULL OR era_end >= era_start)
);
CREATE UNIQUE INDEX machine_eras_one_open_uidx ON public.machine_eras (machine_id) WHERE era_end IS NULL;
CREATE INDEX machine_eras_machine_start_idx ON public.machine_eras (machine_id, era_start);

ALTER TABLE public.machine_eras ENABLE ROW LEVEL SECURITY;
CREATE POLICY machine_eras_admin_select ON public.machine_eras
  FOR SELECT TO authenticated USING (public.is_admin((SELECT auth.uid())));
REVOKE ALL ON public.machine_eras FROM anon;

COMMENT ON TABLE public.machine_eras IS
  'PRD-142a 3.1. One row per machine identity era. Current era = era_end IS NULL. Maintained by sync_machine_eras() nightly.';

-- Partner-sourced predicate (PRD-087 / Portfolio Map rule), one place.
CREATE OR REPLACE FUNCTION public.strategy_population(p_venue_group text, p_official_name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN upper(COALESCE(p_venue_group, '')) IN ('VOX', 'LVLUP', 'LEVELUP')
      OR upper(COALESCE(p_official_name, '')) ~ '(ACTIVATE|IFLY|VOX|MPMCC|LVLUP|LEVELUP)'
    THEN 'partner' ELSE 'boonz' END
$$;
COMMENT ON FUNCTION public.strategy_population(text, text) IS
  'PRD-142a. partner when venue_group in VOX/LVLUP/LEVELUP or official_name contains ACTIVATE/IFLY/VOX/MPMCC/LVLUP/LEVELUP (PRD-087 rule), else boonz.';

CREATE OR REPLACE FUNCTION public.strategy_is_excluded_machine(p_venue_group text, p_official_name text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(p_venue_group, '') = 'WH' OR upper(COALESCE(p_official_name, '')) LIKE 'WH%'
$$;

CREATE OR REPLACE FUNCTION public.sync_machine_eras()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_today   date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_opened  int := 0;
  v_closed  int := 0;
  v_seeded  int := 0;
  r         record;
  v_open    public.machine_eras%ROWTYPE;
BEGIN
  FOR r IN
    WITH s AS (
      SELECT machine_id,
             min((transaction_date AT TIME ZONE 'Asia/Dubai')::date) AS first_sale,
             max((transaction_date AT TIME ZONE 'Asia/Dubai')::date) AS last_sale
      FROM sales_history
      WHERE machine_id IS NOT NULL AND delivery_status IN ('Success', 'Successful')
      GROUP BY machine_id
    )
    SELECT m.machine_id, m.official_name, m.previous_location, m.include_in_refill,
           m.installation_date, s.first_sale, s.last_sale,
           COALESCE((m.relaunched_at AT TIME ZONE 'Asia/Dubai')::date, m.repurposed_at) AS boundary,
           (m.include_in_refill OR s.last_sale >= v_today - 30) AS is_live
    FROM machines m
    LEFT JOIN s USING (machine_id)
    WHERE NOT strategy_is_excluded_machine(m.venue_group, m.official_name)
      AND (s.first_sale IS NOT NULL OR m.include_in_refill)
  LOOP
    SELECT * INTO v_open FROM machine_eras WHERE machine_id = r.machine_id AND era_end IS NULL;

    IF NOT EXISTS (SELECT 1 FROM machine_eras WHERE machine_id = r.machine_id) THEN
      -- Seed.
      IF NOT r.is_live THEN
        INSERT INTO machine_eras (machine_id, venue_label, era_start, era_end, source)
        VALUES (r.machine_id, r.official_name, r.first_sale, r.last_sale, 'archived');
      ELSIF r.boundary IS NOT NULL THEN
        IF r.first_sale IS NOT NULL AND r.first_sale < r.boundary THEN
          INSERT INTO machine_eras (machine_id, venue_label, era_start, era_end, source)
          VALUES (r.machine_id, COALESCE(r.previous_location, r.official_name), r.first_sale, r.boundary - 1, 'seed_prior');
        END IF;
        INSERT INTO machine_eras (machine_id, venue_label, era_start, source)
        VALUES (r.machine_id, r.official_name, r.boundary, 'seed_boundary');
      ELSE
        INSERT INTO machine_eras (machine_id, venue_label, era_start, source)
        VALUES (r.machine_id, r.official_name,
                COALESCE(LEAST(r.installation_date, r.first_sale), r.installation_date, r.first_sale, v_today),
                'seed');
      END IF;
      v_seeded := v_seeded + 1;
      CONTINUE;
    END IF;

    -- Maintain: a new relaunch/repurpose after the open era started.
    IF v_open.era_id IS NOT NULL AND r.boundary IS NOT NULL AND r.boundary > v_open.era_start THEN
      UPDATE machine_eras SET era_end = r.boundary - 1 WHERE era_id = v_open.era_id;
      INSERT INTO machine_eras (machine_id, venue_label, era_start, source)
      VALUES (r.machine_id, r.official_name, r.boundary, 'nightly_boundary');
      UPDATE machine_eras SET venue_label = COALESCE(r.previous_location, venue_label) WHERE era_id = v_open.era_id;
      v_closed := v_closed + 1; v_opened := v_opened + 1;
      INSERT INTO monitoring_alerts (source, severity, payload, acknowledged)
      VALUES ('prd142_machine_eras', 'info',
              jsonb_build_object('machine_id', r.machine_id, 'official_name', r.official_name,
                                 'closed_era_id', v_open.era_id, 'new_era_start', r.boundary,
                                 'note', 'era rolled on relaunched_at/repurposed_at; log only, no ack needed'),
              true);
    ELSIF v_open.era_id IS NOT NULL AND NOT r.is_live THEN
      UPDATE machine_eras SET era_end = GREATEST(COALESCE(r.last_sale, v_open.era_start), v_open.era_start)
      WHERE era_id = v_open.era_id;
      v_closed := v_closed + 1;
      INSERT INTO monitoring_alerts (source, severity, payload, acknowledged)
      VALUES ('prd142_machine_eras', 'info',
              jsonb_build_object('machine_id', r.machine_id, 'official_name', r.official_name,
                                 'closed_era_id', v_open.era_id, 'note', 'machine no longer live; era closed at last sale'),
              true);
    ELSIF v_open.era_id IS NULL AND r.is_live THEN
      INSERT INTO machine_eras (machine_id, venue_label, era_start, source)
      VALUES (r.machine_id, r.official_name,
              COALESCE(r.boundary, (SELECT max(era_end) + 1 FROM machine_eras WHERE machine_id = r.machine_id), v_today),
              'nightly_reopen');
      v_opened := v_opened + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('seeded_machines', v_seeded, 'opened', v_opened, 'closed', v_closed);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.sync_machine_eras() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_machine_eras() TO service_role;

SELECT public.sync_machine_eras();
