-- PRD-044 P0: packing-confirm state columns + in_progress/completed exposure.
-- Forward-only, additive. Much of the model pre-exists (pack_outcome_enum {packed,partial,not_filled};
-- v_machine_pack_status resolved/not_filled/partial/skipped). This adds the two gaps:
--   1) refill_dispatching.not_filled_reason  (reason for a pick-0 not_filled outcome).
--   2) dispatch_pack_confirmation.final       (false = Save & come back / in_progress;
--                                              true  = Finish / completed). Existing rows = true.
-- Then re-expose v_machine_pack_status with pack_final + pack_state ('open'|'in_progress'|'completed').
-- No protected-entity semantics changed; no writer logic here.

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS not_filled_reason text;

ALTER TABLE public.dispatch_pack_confirmation
  ADD COLUMN IF NOT EXISTS final boolean NOT NULL DEFAULT true;

CREATE OR REPLACE VIEW public.v_machine_pack_status AS
 WITH lines AS (
   SELECT rd.machine_id, rd.dispatch_date,
     count(*) FILTER (WHERE (COALESCE(rd.include, true) AND (NOT COALESCE(rd.cancelled, false)))) AS total_included,
     count(*) FILTER (WHERE (COALESCE(rd.include, true) AND (NOT COALESCE(rd.cancelled, false)) AND (rd.packed OR rd.skipped OR (rd.pack_outcome = 'not_filled'::pack_outcome_enum)))) AS resolved,
     count(*) FILTER (WHERE (rd.packed AND COALESCE(rd.include, true) AND (NOT COALESCE(rd.cancelled, false)))) AS physical,
     count(*) FILTER (WHERE ((rd.pack_outcome = 'not_filled'::pack_outcome_enum) AND (NOT COALESCE(rd.cancelled, false)))) AS not_filled,
     count(*) FILTER (WHERE ((rd.pack_outcome = 'partial'::pack_outcome_enum) AND (NOT COALESCE(rd.cancelled, false)))) AS partial,
     count(*) FILTER (WHERE (rd.skipped AND (NOT COALESCE(rd.cancelled, false)))) AS skipped,
     count(*) FILTER (WHERE (rd.packed AND rd.picked_up AND COALESCE(rd.include, true) AND (NOT COALESCE(rd.cancelled, false)))) AS picked_up_physical,
     count(*) FILTER (WHERE (rd.packed AND rd.dispatched AND COALESCE(rd.include, true) AND (NOT COALESCE(rd.cancelled, false)))) AS dispatched_physical
    FROM refill_dispatching rd
   GROUP BY rd.machine_id, rd.dispatch_date
 )
 SELECT l.machine_id, l.dispatch_date, m.official_name AS machine_name,
    l.total_included, l.resolved, l.physical, l.not_filled, l.partial, l.skipped,
    l.picked_up_physical, l.dispatched_physical,
    ((l.total_included > 0) AND (l.resolved = l.total_included)) AS is_pack_complete,
    (l.picked_up_physical = l.physical) AS is_pickup_complete,
    (l.dispatched_physical = l.physical) AS is_dispatch_complete,
    (c.machine_id IS NOT NULL) AS pack_confirmed,
    c.confirmed_at, c.confirmed_by,
    COALESCE(c.final, true) AS pack_final,
    CASE
      WHEN c.machine_id IS NULL THEN 'open'
      WHEN COALESCE(c.final, true) THEN 'completed'
      ELSE 'in_progress'
    END AS pack_state
   FROM ((lines l
     JOIN machines m ON ((m.machine_id = l.machine_id)))
     LEFT JOIN dispatch_pack_confirmation c ON (((c.machine_id = l.machine_id) AND (c.dispatch_date = l.dispatch_date))));
