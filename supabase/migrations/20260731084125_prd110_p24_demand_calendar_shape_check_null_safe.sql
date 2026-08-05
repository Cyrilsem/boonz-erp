-- PRD-110 P2.4 · forward-only correction to chk_demand_calendar_shape (Article 12 — the
-- applied migration is NOT edited).
--
-- ⛔ THE BUG, caught by golden fixture 31 seq 6 on its first green run (shape_rej 2, not 3):
-- a CHECK constraint PASSES when it evaluates to NULL. In the macro_kpi branch,
-- `iso_week BETWEEN 1 AND 53` is NULL when iso_week is NULL, so the branch evaluated to
-- NULL, the whole disjunction evaluated to NULL, and a macro_kpi row carrying NO WEEK was
-- ACCEPTED. The dow branch had the identical hole: a 'dow' row with a NULL dow was accepted
-- for the same reason.
--
-- Such a row would have been silently INERT in the resolver (its temporal predicate could
-- never match), so this would have surfaced as "CS authored a factor and nothing happened" —
-- exactly the class of silent failure LAW 5 exists to forbid.
--
-- FIX: make every range test NULL-safe by guarding it with an explicit IS NOT NULL. The
-- event branch was already safe (its IS NOT NULL guards come first and short-circuit to FALSE).

ALTER TABLE public.demand_calendar DROP CONSTRAINT chk_demand_calendar_shape;

ALTER TABLE public.demand_calendar ADD CONSTRAINT chk_demand_calendar_shape CHECK (
     (source = 'macro_kpi' AND iso_year IS NOT NULL
                           AND iso_week IS NOT NULL AND iso_week BETWEEN 1 AND 53
                           AND dow IS NULL AND valid_from IS NULL AND valid_to IS NULL)
  OR (source = 'dow'       AND dow IS NOT NULL AND dow BETWEEN 0 AND 6
                           AND iso_year IS NULL AND iso_week IS NULL
                           AND valid_from IS NULL AND valid_to IS NULL)
  OR (source = 'event'     AND valid_from IS NOT NULL AND valid_to IS NOT NULL
                           AND valid_to >= valid_from
                           AND iso_year IS NULL AND iso_week IS NULL AND dow IS NULL)
);

-- The constraint is validated against existing rows by ADD CONSTRAINT (no NOT VALID here),
-- so this also proves no malformed row was written in the window between the two migrations.

-- Extend fixture 31 to probe BOTH halves of the hole, not just the one that surfaced.
-- Five malformed shapes now, each a distinct way to be wrong.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$    BEGIN INSERT INTO public.demand_calendar (source, iso_year, note, factor)
          VALUES ('macro_kpi', 2030, 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_shape_rej := v_shape_rej + 1; END;$OLD$,
$NEW$    BEGIN INSERT INTO public.demand_calendar (source, iso_year, note, factor)
          VALUES ('macro_kpi', 2030, 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_shape_rej := v_shape_rej + 1; END;
    -- the NULL-logic hole, other half: macro_kpi with a week but no year
    BEGIN INSERT INTO public.demand_calendar (source, iso_week, note, factor)
          VALUES ('macro_kpi', 6, 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_shape_rej := v_shape_rej + 1; END;
    -- and a 'dow' row carrying no dow at all
    BEGIN INSERT INTO public.demand_calendar (source, note, factor)
          VALUES ('dow', 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_shape_rej := v_shape_rej + 1; END;$NEW$)
 WHERE fixture_id = 31;

UPDATE golden.assertions
   SET expect = '5',
       description = 'chk_shape refuses all FIVE malformed temporal shapes. ⛔ Three of these were ACCEPTED by the first version of the constraint: a CHECK passes when it evaluates to NULL, so `iso_week BETWEEN 1 AND 53` with a NULL iso_week let the row through. Every range test in this constraint must be guarded by an explicit IS NOT NULL'
 WHERE fixture_id = 31 AND seq = 6;
