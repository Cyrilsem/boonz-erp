-- PRD-110 P1.2 - fixture 3 gains the shelf_state truth-layer assertions (phase_required='P1').
-- Fixture 3 is the coverage fixture (MPMCC-1058, "blind machine plans anyway"), so the canonical
-- shelf-state object and its coverage guarantee belong to it. LAW 1: the proof ships with the change.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (3, 10, 'P1.2 coverage: v_shelf_state has exactly one row per non-phantom shelf on an Active+include_in_refill machine',
  $q$SELECT ((SELECT count(*) FROM public.v_shelf_state)
           - (SELECT count(*) FROM public.shelf_configurations sc
                JOIN public.machines m ON m.machine_id = sc.machine_id
               WHERE sc.is_phantom = false AND m.status = 'Active' AND m.include_in_refill = true))::text$q$,
  'eq', '0', true, 'P1'),

 (3, 11, 'P1.2 no fan-out: every v_shelf_state row is a distinct shelf_id',
  $q$SELECT (count(*) - count(DISTINCT shelf_id))::text FROM public.v_shelf_state$q$,
  'eq', '0', true, 'P1'),

 (3, 12, 'G2 fleet-wide: zero in-scope shelves carry a live WEIMI slot with no current slot_lifecycle row',
  $q$SELECT count(*)::text FROM public.v_shelf_state s
      WHERE s.pod_product_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM public.slot_lifecycle sl
                         WHERE sl.shelf_id = s.shelf_id AND sl.archived = false AND sl.is_current = true)$q$,
  'eq', '0', true, 'P1'),

 (3, 13, 'DATA-SOURCE LAW: v_shelf_state pod identity is WEIMI identity, never slot_lifecycle',
  $q$SELECT count(*)::text FROM public.v_shelf_state s
      JOIN public.v_shelf_slot_identity i ON i.shelf_id = s.shelf_id
     WHERE s.pod_product_id IS DISTINCT FROM i.pod_product_id$q$,
  'eq', '0', true, 'P1'),

 (3, 14, 'P1.2 sourcing is total: every shelf with a known pod resolves to a sourcing value',
  $q$SELECT count(*)::text FROM public.v_shelf_state
      WHERE pod_product_id IS NOT NULL AND sourcing IS NULL$q$,
  'eq', '0', true, 'P1'),

 (3, 15, 'P1.2 placeholders are explicit NULLs, not guesses (velocity_instock -> P2.1, composition_confidence -> P1.4; re-phase then)',
  $q$SELECT (count(*) FILTER (WHERE velocity_instock IS NOT NULL)
           + count(*) FILTER (WHERE composition_confidence IS NOT NULL))::text
      FROM public.v_shelf_state$q$,
  'eq', '0', true, 'P1'),

 (3, 16, 'S-10/S-06 truth layer: ACTIVATEMCC-1037 Fade Fit shelves read sourcing=venue in shelf_state (2 shelves)',
  $q$SELECT count(*)::text FROM public.v_shelf_state
      WHERE machine_name = 'ACTIVATEMCC-1037-0000-L0' AND pod_name = 'Fade Fit' AND sourcing = 'venue'$q$,
  'eq', '2', true, 'P1'),

 (3, 17, 'P1.2 coverage guarantee is installed: single-shelf provisioner + non-phantom INSERT trigger',
  $q$SELECT ((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname='public' AND p.proname='provision_shelf_lifecycle_v3')
          + (SELECT count(*) FROM pg_trigger t
              WHERE t.tgrelid = 'public.shelf_configurations'::regclass
                AND t.tgname = 'tg_provision_shelf_lifecycle_ins' AND NOT t.tgisinternal))::text$q$,
  'eq', '2', true, 'P1'),

 (3, 18, 'P1.2 velocity grain safety: pod_shelf_count (the replication factor) is present on every shelf with a known pod',
  $q$SELECT count(*)::text FROM public.v_shelf_state
      WHERE pod_product_id IS NOT NULL AND pod_shelf_count IS NULL$q$,
  'eq', '0', true, 'P1')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description = EXCLUDED.description, check_sql = EXCLUDED.check_sql,
      expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
      enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;
