-- Loop 2026-09-25 B1 (PRD-133): picker_config switch table and machines_to_visit_shadow.
--
-- picker_config holds the single switch that decides which picker (v11, pick_machines_for_refill;
-- v12, pick_machines_v12, added in a later step of this same loop) is authoritative for a given
-- plan_date, and which one only writes to the shadow comparison table instead of the real
-- machines_to_visit table:
--   'v11'    -> v11 only, current behaviour, unchanged.
--   'shadow' -> v11 decides (writes machines_to_visit as today); v12 also runs and writes its
--               picks to machines_to_visit_shadow, never touching the real plan.
--   'v12'    -> v12 decides; v11 still runs, its output going to machines_to_visit_shadow instead.
-- Seeded to 'shadow'.
--
-- machines_to_visit_shadow is NOT a clone of the (much larger, v11-specific) machines_to_visit
-- table. It holds exactly what a picker run reports, tagged by which picker produced it, shaped
-- like pick_machines_v12's own return columns (PRD-133), so both v11 and v12 write the same shape
-- when they are the non-authoritative side of the switch. This is state a picker run itself
-- produces each time it runs, not a materialized copy of a query result, so Article 14 does not
-- require an ADR here (per the corrected reading: a shadow table an engine writes during a
-- parallel-run migration is permitted with ordinary Article 2/4/8 discipline).
--
-- Wiring the switch into the entry point that calls pick_machines_for_refill
-- (_build_draft_core_v3, called by both build_draft_for_confirmed and the 6am pre-pick job,
-- confirmed by reading the actual call chain) is deferred to the step that adds pick_machines_v12
-- itself: the switch cannot call a function that does not exist yet, and wiring it in two pieces
-- across two migrations, rather than one migration touching a function that half-references
-- something not yet created, keeps each step independently valid. See STATE.md.
--
-- No function is created or changed by this migration, so the rolled-back smoke call rule does
-- not apply; verified instead by reading back the seeded row and the table shapes after apply.

CREATE TABLE public.picker_config (
  key         text PRIMARY KEY,
  value       text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid
);

ALTER TABLE public.picker_config ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.picker_config FROM authenticated;
REVOKE ALL ON public.picker_config FROM anon, PUBLIC;

-- Read-only for authenticated. INSERT/UPDATE/DELETE/TRUNCATE are revoked from authenticated above
-- (S-308: a REVOKE ALL FROM anon, PUBLIC does not touch a grant held by authenticated; the grant
-- must be revoked explicitly, or every new table is born writable by any signed-in user). No write
-- policy is added for authenticated: with the grant revoked, an RLS write policy here would be
-- inert and misleading, not a real permission ("RLS covering it is luck, not posture"). Writes to
-- this table happen only via elevated (table-owner / service-role) access, the same access this
-- migration itself uses, with app.mutation_reason set per this loop's hard rules.
CREATE POLICY picker_config_authenticated_select ON public.picker_config
  FOR SELECT TO authenticated
  USING (true);

INSERT INTO public.picker_config (key, value, updated_by)
VALUES ('picker_version', 'shadow', NULL);

CREATE TABLE public.machines_to_visit_shadow (
  plan_date       date NOT NULL,
  picker_version  text NOT NULL CHECK (picker_version IN ('v11','v12')),
  machine_id      uuid NOT NULL REFERENCES public.machines(machine_id),
  official_name   text NOT NULL,
  tier            text,
  visit_value_aed numeric,
  reasons         text[] NOT NULL DEFAULT '{}',
  building_id     uuid,
  cluster_role    text,
  donor_for       jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (plan_date, picker_version, machine_id)
);

ALTER TABLE public.machines_to_visit_shadow ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.machines_to_visit_shadow FROM authenticated;
REVOKE ALL ON public.machines_to_visit_shadow FROM anon, PUBLIC;

-- Same posture as picker_config above: read-only for authenticated, writes revoked from
-- authenticated at the grant layer. The picker function that writes here (added when
-- pick_machines_v12 lands) is SECURITY DEFINER and owned by the table owner, so it writes
-- regardless of this REVOKE; no direct client write path exists or is needed.
CREATE POLICY machines_to_visit_shadow_authenticated_select ON public.machines_to_visit_shadow
  FOR SELECT TO authenticated
  USING (true);
