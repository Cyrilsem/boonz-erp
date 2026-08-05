-- PRD-110 P3.1c — S-88 sweep: revoke TRUNCATE from `authenticated` on every table
-- PRD-110 created. Forward-only (Article 12).
--
-- ⛔ THE FINDING. Supabase's ALTER DEFAULT PRIVILEGES grants `authenticated` ALL privileges
--    on each new table in `public`. Every PRD-110 migration that created a table enabled RLS
--    and wrote policies - which correctly gate SELECT/INSERT/UPDATE/DELETE - and stopped there.
--
-- ⛔ BUT TRUNCATE IS NOT A ROW OPERATION. It bypasses RLS entirely and fires no FOR EACH ROW
--    trigger. So on all seven tables below, any authenticated user could erase the whole table
--    in one statement, regardless of policy, and regardless of an append-only trigger:
--      inventory_events    - append-only event log (Article 7)
--      product_sourcing    - append-only sourcing versioning (P1.1)
--      blocked_demand      - the LAW 5 ledger
--      machines_to_visit   - the Gate-0 table (1,240 rows)
--      shelf_composition / inventory_anomalies / demand_calendar
--
-- Found by golden fixture 44 seq 25, written against the table THIS leg created; the sweep
-- then showed the same hole on seven siblings (S-79 habit: close the sweep, do not sample).
--
-- ⭐ SAFE BY INSPECTION: TRUNCATE only. INSERT/UPDATE/DELETE grants are left exactly as they
--    are, because RLS already gates them and revoking could break a legitimate FE path.
--    Probed before applying: 0 functions and 0 cron jobs anywhere issue TRUNCATE against any
--    of these tables, so nothing legitimate loses a capability.

REVOKE TRUNCATE ON public.blocked_demand       FROM authenticated;
REVOKE TRUNCATE ON public.demand_calendar      FROM authenticated;
REVOKE TRUNCATE ON public.inventory_anomalies  FROM authenticated;
REVOKE TRUNCATE ON public.inventory_events     FROM authenticated;
REVOKE TRUNCATE ON public.machines_to_visit    FROM authenticated;
REVOKE TRUNCATE ON public.product_sourcing     FROM authenticated;
REVOKE TRUNCATE ON public.shelf_composition    FROM authenticated;
