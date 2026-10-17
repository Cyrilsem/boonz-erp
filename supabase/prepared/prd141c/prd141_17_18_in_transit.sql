-- PRD-141 items 17 (E1) and 18: packed bags that were picked up and not delivered are visible, and a new
-- plan for such a machine is tagged as a top-up.
-- 17. v_machine_pack_status appends in_transit_n, in_transit_units, in_transit: lines packed and picked up,
--     not received (item_added), not returned, no driver outcome (sweep_stale_delivered_lines marks
--     assumed deliveries delivered_unconfirmed), not cancelled, fill actions only, dated within the last
--     7 days up to today (56 legacy rows from March to September and a 2030 VOXMCC row are data debt, not
--     bags in the van; listed in the log). The Home "In the van" card and the
--     Dispatching list read it (FE, day window); age = today - dispatch_date (no pickup timestamp exists).
-- 18. write_refill_plan appends "[top_up_on_transit <date>]" to the comment of every line for a machine
--     with in-transit bags from an earlier date (suffix, never prefix: [sub] and other prefixes are parsed),
--     and returns top_up_on_transit_machines as a warning. The pack screen renders the tag as
--     "Deliver with the bags of <date>" (FE).
-- Rollback: supabase/rollbacks/prd141_17_18_rollback.sql.

CREATE OR REPLACE VIEW public.v_machine_pack_status AS
 WITH lines AS (
         SELECT rd.machine_id,
            rd.dispatch_date,
            count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS total_included,
            count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false) AND (rd.packed OR rd.skipped OR rd.pack_outcome = 'not_filled'::pack_outcome_enum)) AS resolved,
            count(*) FILTER (WHERE rd.packed AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS physical,
            count(*) FILTER (WHERE rd.pack_outcome = 'not_filled'::pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS not_filled,
            count(*) FILTER (WHERE rd.pack_outcome = 'partial'::pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS partial,
            count(*) FILTER (WHERE rd.skipped AND NOT COALESCE(rd.cancelled, false)) AS skipped,
            count(*) FILTER (WHERE rd.packed AND rd.picked_up AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS picked_up_physical,
            count(*) FILTER (WHERE rd.packed AND rd.dispatched AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS dispatched_physical,
            count(*) FILTER (WHERE rd.packed AND rd.picked_up AND NOT COALESCE(rd.item_added, false) AND NOT COALESCE(rd.returned, false) AND rd.driver_outcome IS NULL AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false) AND (rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text, 'Add'::text]))) AS in_transit_n,
            COALESCE(sum(rd.quantity) FILTER (WHERE rd.packed AND rd.picked_up AND NOT COALESCE(rd.item_added, false) AND NOT COALESCE(rd.returned, false) AND rd.driver_outcome IS NULL AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false) AND (rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text, 'Add'::text]))), 0::numeric) AS in_transit_units
           FROM refill_dispatching rd
          GROUP BY rd.machine_id, rd.dispatch_date
        )
 SELECT l.machine_id,
    l.dispatch_date,
    m.official_name AS machine_name,
    l.total_included,
    l.resolved,
    l.physical,
    l.not_filled,
    l.partial,
    l.skipped,
    l.picked_up_physical,
    l.dispatched_physical,
    COALESCE(p.ready_to_pack_close, false) AS is_pack_complete,
    l.total_included > 0 AND l.picked_up_physical = l.physical AS is_pickup_complete,
    l.total_included > 0 AND l.dispatched_physical = l.physical AS is_dispatch_complete,
    c.machine_id IS NOT NULL AS pack_confirmed,
    c.confirmed_at,
    c.confirmed_by,
    COALESCE(c.final, true) AS pack_final,
        CASE
            WHEN c.machine_id IS NULL AND COALESCE(p.ready_to_pack_close, false) THEN 'completed'::text
            WHEN c.machine_id IS NULL THEN 'open'::text
            WHEN COALESCE(c.final, true) AND NOT COALESCE(p.ready_to_pack_close, false) THEN 'needs_reconfirm'::text
            WHEN COALESCE(c.final, true) THEN 'completed'::text
            ELSE 'in_progress'::text
        END AS pack_state,
    c.machine_id IS NOT NULL AND COALESCE(c.final, true) AND NOT COALESCE(p.ready_to_pack_close, false) AS needs_reconfirm,
    GREATEST(COALESCE(p.packable_n, 0::bigint) - COALESCE(p.resolved_n, 0::bigint), 0::bigint) AS unresolved_n,
    CASE WHEN l.dispatch_date BETWEEN (now() AT TIME ZONE 'Asia/Dubai'::text)::date - 7 AND (now() AT TIME ZONE 'Asia/Dubai'::text)::date THEN l.in_transit_n ELSE 0::bigint END AS in_transit_n,
    CASE WHEN l.dispatch_date BETWEEN (now() AT TIME ZONE 'Asia/Dubai'::text)::date - 7 AND (now() AT TIME ZONE 'Asia/Dubai'::text)::date THEN l.in_transit_units ELSE 0::numeric END AS in_transit_units,
    l.dispatch_date BETWEEN (now() AT TIME ZONE 'Asia/Dubai'::text)::date - 7 AND (now() AT TIME ZONE 'Asia/Dubai'::text)::date AND l.in_transit_n > 0 AS in_transit
   FROM lines l
     JOIN machines m ON m.machine_id = l.machine_id
     LEFT JOIN dispatch_pack_confirmation c ON c.machine_id = l.machine_id AND c.dispatch_date = l.dispatch_date
     LEFT JOIN v_dispatch_pack_progress p ON p.machine_id = l.machine_id AND p.dispatch_date = l.dispatch_date;

DO $patch$
DECLARE
  v_def text; n int; i int;
  pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.write_refill_plan(date,jsonb)'::regprocedure);
  pairs := ARRAY[
    ARRAY['      line->>''comment'',' || chr(10) || '      ''pending'',',
          '      NULLIF(concat_ws('' '', NULLIF(line->>''comment'', ''''),' || chr(10)
          || '        (SELECT format(''[top_up_on_transit %s]'', max(t.dispatch_date))  -- PRD-141 item 18' || chr(10)
          || '           FROM public.refill_dispatching t JOIN public.machines tm ON tm.machine_id = t.machine_id' || chr(10)
          || '          WHERE tm.official_name = line->>''machine_name'' AND t.dispatch_date < p_plan_date' || chr(10)
          || '            AND t.dispatch_date >= p_plan_date - 7 AND t.packed AND t.picked_up AND NOT COALESCE(t.item_added, false) AND NOT COALESCE(t.returned, false) AND t.driver_outcome IS NULL' || chr(10)
          || '            AND NOT COALESCE(t.cancelled, false) AND t.action IN (''Refill'',''Add New'',''Add'')' || chr(10)
          || '          HAVING count(*) > 0)), ''''),' || chr(10)
          || '      ''pending'','],
    ARRAY['    ''preflight_version'', ''v8_weimi_remove_gate'',',
          '    ''preflight_version'', ''v8_weimi_remove_gate'',' || chr(10)
          || '    ''top_up_on_transit_machines'', (SELECT COALESCE(jsonb_agg(DISTINCT tm.official_name), ''[]''::jsonb)' || chr(10)
          || '       FROM public.refill_dispatching t JOIN public.machines tm ON tm.machine_id = t.machine_id' || chr(10)
          || '      WHERE tm.official_name = ANY(v_machine_names) AND t.dispatch_date < p_plan_date' || chr(10)
          || '        AND t.dispatch_date >= p_plan_date - 7 AND t.packed AND t.picked_up AND NOT COALESCE(t.item_added, false) AND NOT COALESCE(t.returned, false) AND t.driver_outcome IS NULL' || chr(10)
          || '        AND NOT COALESCE(t.cancelled, false) AND t.action IN (''Refill'',''Add New'',''Add'')),']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_18: write_refill_plan anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) TO authenticated, service_role;
