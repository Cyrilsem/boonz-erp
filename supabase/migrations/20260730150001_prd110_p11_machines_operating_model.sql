-- PRD-110 P1.1(i) - machines.operating_model (WS-J1), column only. BACKFILL IS PARKED.
--
-- WHY: today the three operating models are INFERRED at read time from venue_group + the presence
-- of VOXSOURCE-999 sentinel rows. WS-J1 makes the model first-class so planning, reconciliation and
-- anomaly rules stop guessing. LAW 2 (truth before intelligence): this is the Phase-1 blocker.
--
-- SPEC CORRECTION (logged, house pattern per S-04 / LAW 13):
--   BUILD SPEC P1.1 says `operating_model enum(...) NOT NULL`. Both halves are unshippable AS WRITTEN
--   in the same migration as the backfill, because the same clause also says CS reviews the generated
--   mapping BEFORE apply, and the goal command PARKING protocol lists "operating-model backfill apply"
--   as a DECISIONS-READY item. A NOT NULL column with a parked backfill cannot exist.
--   IMPLEMENTED INTENT: nullable TEXT + CHECK now; NULL means "CS has not classified this machine yet"
--   and every operating-model rule is INERT for such a machine (no silent default). The NOT NULL
--   promotion is part of the parked activation script, after the backfill lands.
--   CHECK not native enum: matches the house pattern (blocked_demand.reason, .source, .resolution).
--
-- Cody class (a) DDL on a protected entity (`machines`, Appendix A).
--   Article 12 - additive, forward-only. No DROP, no edit-in-place, no rewrite of a past migration.
--   Article 2  - `machines` RLS unchanged (adding a column changes no policy).
--   Article 3  - NO data is written here. The backfill is a separate RPC (20260730150003) and its
--                apply is parked; a raw UPDATE on `machines` would violate Articles 1 and 3.
--   Article 14 - no new table; `v_machine_operating_model_proposed` is a VIEW precisely so the
--                generated mapping can never go stale against the machines it describes.

ALTER TABLE public.machines
  ADD COLUMN IF NOT EXISTS operating_model text NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'machines_operating_model_check') THEN
    ALTER TABLE public.machines
      ADD CONSTRAINT machines_operating_model_check
      CHECK (operating_model IS NULL
          OR operating_model IN ('fully_managed','co_managed','partner_managed'));
  END IF;
END $$;

COMMENT ON COLUMN public.machines.operating_model IS
  'PRD-110 WS-J1. fully_managed = all products Boonz-sourced (any stock rise without a Boonz event '
  'is an anomaly). co_managed = per-product sourcing edge in product_sourcing (rise on a '
  'venue-sourced product is a legitimate venue_fill). partner_managed = zero Boonz inventory '
  'records, engine plans nothing. NULL = not yet classified by CS; every operating-model rule is '
  'INERT while NULL, deliberately - there is no silent default. Written ONLY by '
  'set_machine_operating_model_v3.';

-- The GENERATED mapping, as a view so it can never drift from the machines it classifies.
-- Rule per BUILD SPEC P1.1: venue_group='VOX' -> co_managed; LVLUP/LevelUp -> partner_managed;
-- else fully_managed. Restricted to status='Active' machines: the 2 Inactive warehouse
-- pseudo-machines (WH1-2002, WH2-2001) are not real venues and must not be auto-classified.
CREATE OR REPLACE VIEW public.v_machine_operating_model_proposed
WITH (security_invoker = true) AS
SELECT m.machine_id,
       m.official_name,
       m.venue_group,
       m.status,
       m.include_in_refill,
       m.operating_model                                   AS current_model,
       CASE WHEN m.venue_group = 'VOX' THEN 'co_managed'
            WHEN m.venue_group = 'LVLUP'
              OR m.official_name ILIKE '%LVLUP%'
              OR m.official_name ILIKE '%LEVELUP%'         THEN 'partner_managed'
            ELSE 'fully_managed' END                       AS proposed_model,
       (m.operating_model IS DISTINCT FROM
         CASE WHEN m.venue_group = 'VOX' THEN 'co_managed'
              WHEN m.venue_group = 'LVLUP'
                OR m.official_name ILIKE '%LVLUP%'
                OR m.official_name ILIKE '%LEVELUP%'       THEN 'partner_managed'
              ELSE 'fully_managed' END)                    AS would_change
  FROM public.machines m
 WHERE m.status = 'Active';

COMMENT ON VIEW public.v_machine_operating_model_proposed IS
  'PRD-110 P1.1(i). The GENERATED operating-model mapping CS reviews before apply (BUILD SPEC P1.1). '
  'A view, not a snapshot table, so it cannot go stale (Article 14). Apply is PARKED - see '
  'PRD-110-PARKING-LOT D-07 and apply_proposed_operating_models_v3.';

GRANT SELECT ON public.v_machine_operating_model_proposed TO authenticated;
