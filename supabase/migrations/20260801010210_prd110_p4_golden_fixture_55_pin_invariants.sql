SET LOCAL statement_timeout = '90s';

-- ============================================================================
-- PRD-110 leg 79 — golden fixture 55: P4.2 planning-pin schema invariants.
-- LAW 1: this is the fixture that proves 20260801005744.
-- ⭐ S-117 DESIGNED IN, not discovered: every row this fixture writes carries a
--    DETERMINISTIC uuid, so cleanup at the top is exact and a re-run is a no-op.
--    Writes go to the three new v3 tables + golden.scratch and NOWHERE else.
-- ============================================================================

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes, scenario_sql)
VALUES (
  55,
  'Planning-pin schema invariants: provenance actually bites, kind/value and mode/expiry pair, the always/never contradiction is unrepresentable, expiry frees the uniqueness slot, and the canonical view hides revoked AND expired pins (P4.1/P4.2)',
  'PRD-110 P4.1/P4.2 schema, Cody review leg 79',
  'P4',
  DATE '2030-02-25',
  'passing',
  true,
  'Article 16 note: this oracle reads planning_pins_v3 (the BASE table) directly when it is asserting what the base table permits, and reads v_planning_pins_active_v3 only when asserting the canonical active definition. That split is deliberate - a constraint test that went through the view could not see a revoked row at all. Do NOT "fix" it by routing everything through the view.',
$SCEN$
DO $fx55$
DECLARE
  m uuid; p1 uuid; p2 uuid; s1 uuid;
  fb1 uuid := '55550000-0000-0000-0000-000000000001';
  fb2 uuid := '55550000-0000-0000-0000-000000000002';
  pr1 uuid := '55550000-0000-0000-0000-0000000000a1';
  pin_ok uuid := '55550000-0000-0000-0000-0000000000b1';
  pin_exp uuid := '55550000-0000-0000-0000-0000000000b2';
  pin_rev uuid := '55550000-0000-0000-0000-0000000000b3';
  pin_always uuid := '55550000-0000-0000-0000-0000000000b4';
  pin_remint uuid := '55550000-0000-0000-0000-0000000000b5';
  v_state text;
BEGIN
  -- ---- idempotent cleanup, exact by construction (children before parents) ----
  DELETE FROM public.planning_pins_v3
    WHERE pin_id IN (pin_ok, pin_exp, pin_rev, pin_always, pin_remint);
  DELETE FROM public.feedback_proposals_v3 WHERE proposal_id = pr1;
  DELETE FROM public.feedback_ledger_v3    WHERE feedback_id IN (fb1, fb2);
  DELETE FROM golden.scratch WHERE fixture_id = 55;

  -- deterministic real anchors (FKs are RESTRICT, so these must be live rows)
  SELECT machine_id INTO m FROM public.shelf_configurations
    GROUP BY machine_id ORDER BY machine_id LIMIT 1;
  SELECT product_id INTO p1 FROM public.boonz_products ORDER BY product_id LIMIT 1;
  SELECT product_id INTO p2 FROM public.boonz_products ORDER BY product_id OFFSET 1 LIMIT 1;
  SELECT shelf_id INTO s1 FROM public.shelf_configurations
    WHERE machine_id = m ORDER BY shelf_id LIMIT 1;

  INSERT INTO golden.scratch(fixture_id,key,value) VALUES
    (55,'anchor_machine', to_jsonb(m::text)),
    (55,'anchor_p1', to_jsonb(p1::text)),
    (55,'anchor_p2', to_jsonb(p2::text));

  -- ---- the happy path: feedback -> proposal -> approved -> pin ----
  INSERT INTO public.feedback_ledger_v3
    (feedback_id, channel, machine_id, shelf_id, boonz_product_id, intent, note, status, triaged_at)
  VALUES (fb1,'client',m,s1,p1,'dont_reduce','FX55 client asked us not to reduce this depth','proposed',now()),
         (fb2,'cs',    m,s1,p2,'always_stock','FX55 CS standing instruction to always stock','proposed',now());

  INSERT INTO public.feedback_proposals_v3
    (proposal_id, plan_date, machine_id, shelf_id, boonz_product_id, pin_kind, pin_value,
     pin_mode, feedback_ids, trigger_reason, status, reviewed_at)
  VALUES (pr1, {{plan_date}}, m, s1, p1, 'protect_depth', 4, 'perpetual',
          ARRAY[fb1], 'FX55 probe: client depth request', 'approved', now());

  INSERT INTO public.planning_pins_v3
    (pin_id, machine_id, shelf_id, boonz_product_id, kind, value, mode, source, feedback_ids, proposal_id)
  VALUES (pin_ok, m, s1, p1, 'protect_depth', 4, 'perpetual', 'feedback', ARRAY[fb1], pr1);
  UPDATE public.feedback_proposals_v3 SET applied_pin_id = pin_ok WHERE proposal_id = pr1;

  -- an ALREADY-EXPIRED until-mode pin, and a REVOKED pin: both must vanish from the view
  INSERT INTO public.planning_pins_v3
    (pin_id, machine_id, shelf_id, boonz_product_id, kind, value, mode, expires_at,
     source, feedback_ids, proposal_id)
  VALUES (pin_exp, m, s1, p2, 'min_facing', 2, 'until', now() - interval '1 day',
          'feedback', ARRAY[fb2], NULL);
  INSERT INTO public.planning_pins_v3
    (pin_id, machine_id, shelf_id, boonz_product_id, kind, value, mode,
     source, feedback_ids, revoked_at, revoked_by, revoke_reason)
  VALUES (pin_rev, m, s1, p2, 'protect_depth', 9, 'perpetual',
          'feedback', ARRAY[fb2], now(),
          '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, 'FX55 revoked by hand');
  -- ⛔ NO exception handler here on purpose. A plpgsql handler rolls the whole
  -- block back, so a swallowed setup error would silently erase the happy path
  -- and leave the negative probes asserting against an empty table - green, and
  -- meaningless. Setup failures must be LOUD.
END
$fx55$;

-- ---- the negative probes: each bad write must be REFUSED, and by the right rule ----
DO $fx55b$
DECLARE
  m uuid; p1 uuid; p2 uuid; s1 uuid;
  fb1 uuid := '55550000-0000-0000-0000-000000000001';
  fb2 uuid := '55550000-0000-0000-0000-000000000002';
  pr1 uuid := '55550000-0000-0000-0000-0000000000a1';
  pin_always uuid := '55550000-0000-0000-0000-0000000000b4';
  pin_remint uuid := '55550000-0000-0000-0000-0000000000b5';
BEGIN
  SELECT machine_id INTO m FROM public.shelf_configurations GROUP BY machine_id ORDER BY machine_id LIMIT 1;
  SELECT product_id INTO p1 FROM public.boonz_products ORDER BY product_id LIMIT 1;
  SELECT product_id INTO p2 FROM public.boonz_products ORDER BY product_id OFFSET 1 LIMIT 1;
  SELECT shelf_id INTO s1 FROM public.shelf_configurations WHERE machine_id = m ORDER BY shelf_id LIMIT 1;

  -- (a) ⭐ THE ONE CODY CAUGHT: an evidence-free proposal. array_length('{}',1) is
  --     NULL and a NULL CHECK PASSES, so before the cardinality() fix this INSERT
  --     SUCCEEDED. This probe is the regression test for that exact trap.
  BEGIN
    INSERT INTO public.feedback_proposals_v3
      (plan_date, machine_id, boonz_product_id, pin_kind, pin_value, pin_mode, feedback_ids, trigger_reason)
    VALUES ({{plan_date}}, m, p1, 'protect_depth', 3, 'perpetual', '{}'::uuid[], 'FX55 evidence-free');
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_a', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN check_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_a', to_jsonb('REFUSED_CHECK'::text));
  END;

  -- (b) feedback-sourced pin with no feedback ids: same trap, pin side
  BEGIN
    INSERT INTO public.planning_pins_v3
      (machine_id, boonz_product_id, kind, value, mode, source, feedback_ids)
    VALUES (m, p1, 'min_facing', 2, 'perpetual', 'feedback', '{}'::uuid[]);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_b', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN check_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_b', to_jsonb('REFUSED_CHECK'::text));
  END;

  -- (c) protect_depth with NULL value
  BEGIN
    INSERT INTO public.planning_pins_v3
      (machine_id, boonz_product_id, kind, value, mode, source, feedback_ids)
    VALUES (m, p1, 'protect_depth', NULL, 'perpetual', 'feedback', ARRAY[fb1]);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_c', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN check_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_c', to_jsonb('REFUSED_CHECK'::text));
  END;

  -- (d) always_stock carrying a value it must not have
  BEGIN
    INSERT INTO public.planning_pins_v3
      (machine_id, boonz_product_id, kind, value, mode, source, feedback_ids)
    VALUES (m, p1, 'always_stock', 5, 'perpetual', 'feedback', ARRAY[fb1]);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_d', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN check_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_d', to_jsonb('REFUSED_CHECK'::text));
  END;

  -- (e) mode='until' with no expiry
  BEGIN
    INSERT INTO public.planning_pins_v3
      (machine_id, boonz_product_id, kind, value, mode, source, feedback_ids)
    VALUES (m, p1, 'min_facing', 2, 'until', 'feedback', ARRAY[fb1]);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_e', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN check_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_e', to_jsonb('REFUSED_CHECK'::text));
  END;

  -- (f) a second LIVE pin of the same kind on the same target
  BEGIN
    INSERT INTO public.planning_pins_v3
      (machine_id, shelf_id, boonz_product_id, kind, value, mode, source, feedback_ids)
    VALUES (m, s1, p1, 'protect_depth', 7, 'perpetual', 'feedback', ARRAY[fb1]);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_f', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_f', to_jsonb('REFUSED_UNIQUE'::text));
  END;

  -- (g) ⭐ THE CONTRADICTION GUARD. Mint always_stock, then try never_stock on the
  --     same target. Both kinds share one uniqueness bucket, so this is 23505 -
  --     an incoherent rule is physically unrepresentable, with no trigger to race.
  INSERT INTO public.planning_pins_v3
    (pin_id, machine_id, shelf_id, boonz_product_id, kind, value, mode, source, feedback_ids)
  VALUES (pin_always, m, s1, p2, 'always_stock', NULL, 'perpetual', 'feedback', ARRAY[fb2]);
  BEGIN
    INSERT INTO public.planning_pins_v3
      (machine_id, shelf_id, boonz_product_id, kind, value, mode, source, feedback_ids)
    VALUES (m, s1, p2, 'never_stock', NULL, 'perpetual', 'feedback', ARRAY[fb2]);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_g', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_g', to_jsonb('REFUSED_UNIQUE'::text));
  END;

  -- (h) hand-revoked with no revoker and a non-system reason
  BEGIN
    INSERT INTO public.planning_pins_v3
      (machine_id, boonz_product_id, kind, value, mode, source, feedback_ids,
       revoked_at, revoked_by, revoke_reason)
    VALUES (m, p1, 'min_facing', 3, 'perpetual', 'feedback', ARRAY[fb1],
            now(), NULL, 'FX55 no revoker named');
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_h', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN check_violation THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_h', to_jsonb('REFUSED_CHECK'::text));
  END;

  -- (i) ⭐ CODY REVISION (3), THE POINT OF THE WHOLE EXEMPTION: a lapsed pin must
  --     be able to LEAVE the uniqueness slot. Retire always_stock as an EXPIRY
  --     (system actor, no human), then re-mint the same kind on the same target.
  --     Before the exemption this sequence was impossible and the slot was a
  --     permanent tombstone.
  UPDATE public.planning_pins_v3
     SET revoked_at = now(), revoked_by = NULL, revoke_reason = 'expired_system'
   WHERE pin_id = pin_always;
  BEGIN
    INSERT INTO public.planning_pins_v3
      (pin_id, machine_id, shelf_id, boonz_product_id, kind, value, mode, source, feedback_ids)
    VALUES (pin_remint, m, s1, p2, 'always_stock', NULL, 'perpetual', 'feedback', ARRAY[fb2]);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_i', to_jsonb('REMINTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (55,'probe_i', to_jsonb(('BLOCKED_'||SQLSTATE)::text));
  END;
END
$fx55b$;
$SCEN$
)
ON CONFLICT (fixture_id) DO UPDATE
  SET name = EXCLUDED.name, scenario_sql = EXCLUDED.scenario_sql, notes = EXCLUDED.notes,
      phase_required = EXCLUDED.phase_required, plan_date = EXCLUDED.plan_date,
      baseline_status = EXCLUDED.baseline_status, enabled = EXCLUDED.enabled;

-- ============================ assertions ============================
DELETE FROM golden.assertions WHERE fixture_id = 55;
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- ---- the eight refusals. Each names the RULE that must do the refusing. ----
(55,1,'⭐ THE CODY CATCH: an evidence-free proposal is REFUSED. array_length(''{}'',1) is NULL and a NULL CHECK PASSES, so before cardinality() this row was ACCEPTED. This is the regression test for that trap.',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_a'$$,'eq','REFUSED_CHECK',true,'P4'),
(55,2,'A feedback-sourced pin with no feedback ids is REFUSED (same NULL-CHECK trap, pin side)',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_b'$$,'eq','REFUSED_CHECK',true,'P4'),
(55,3,'protect_depth with a NULL value is REFUSED (kind/value pairing)',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_c'$$,'eq','REFUSED_CHECK',true,'P4'),
(55,4,'always_stock carrying a value is REFUSED (kind/value pairing, other direction)',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_d'$$,'eq','REFUSED_CHECK',true,'P4'),
(55,5,'mode=''until'' with no expires_at is REFUSED (mode/expiry pairing)',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_e'$$,'eq','REFUSED_CHECK',true,'P4'),
(55,6,'A second LIVE pin of the same kind on the same target is REFUSED by the partial unique index, not by a trigger',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_f'$$,'eq','REFUSED_UNIQUE',true,'P4'),
(55,7,'⭐ THE CONTRADICTION GUARD: never_stock while always_stock is live raises 23505. Both kinds share one uniqueness bucket, so an incoherent rule is UNREPRESENTABLE - no trigger to race, nothing to drop.',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_g'$$,'eq','REFUSED_UNIQUE',true,'P4'),
(55,8,'A revocation with no named revoker and a non-system reason is REFUSED (Article 4/8 attribution)',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_h'$$,'eq','REFUSED_CHECK',true,'P4'),
-- ---- the exemption that makes the uniqueness index survivable ----
(55,9,'⭐ CODY REVISION 3: a lapsed pin LEAVES the uniqueness slot. Retired as expired_system (no human actor) then re-minted on the same target. Without the exemption the slot was a permanent tombstone and no until-mode pin could ever be renewed.',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=55 AND key='probe_i'$$,'eq','REMINTED',true,'P4'),
-- ---- the canonical view: Article 16 ----
(55,10,'The approved perpetual pin is ACTIVE in the canonical view',
 $$SELECT count(*)::text FROM public.v_planning_pins_active_v3 WHERE pin_id='55550000-0000-0000-0000-0000000000b1'$$,'eq','1',true,'P4'),
(55,11,'⭐ The EXPIRED pin still exists in the base table - history is never destroyed',
 $$SELECT count(*)::text FROM public.planning_pins_v3 WHERE pin_id='55550000-0000-0000-0000-0000000000b2'$$,'eq','1',true,'P4'),
(55,12,'...but the canonical view HIDES it. Expiry is a view-time predicate, which is why the unique index (which cannot call now()) needed the expired_system exemption at all.',
 $$SELECT count(*)::text FROM public.v_planning_pins_active_v3 WHERE pin_id='55550000-0000-0000-0000-0000000000b2'$$,'eq','0',true,'P4'),
(55,13,'The REVOKED pin also survives in the base table (supersede, never DELETE - the fixture-16 chain depends on this)',
 $$SELECT count(*)::text FROM public.planning_pins_v3 WHERE pin_id='55550000-0000-0000-0000-0000000000b3'$$,'eq','1',true,'P4'),
(55,14,'...and the canonical view hides the revoked pin too',
 $$SELECT count(*)::text FROM public.v_planning_pins_active_v3 WHERE pin_id='55550000-0000-0000-0000-0000000000b3'$$,'eq','0',true,'P4'),
(55,15,'The view exposes days_remaining as NULL for a perpetual pin (a perpetual pin has no clock)',
 $$SELECT coalesce((SELECT days_remaining::text FROM public.v_planning_pins_active_v3 WHERE pin_id='55550000-0000-0000-0000-0000000000b1'),'NULL')$$,'eq','NULL',true,'P4'),
(55,16,'The view marks the perpetual pin as not time-boxed',
 $$SELECT is_time_boxed::text FROM public.v_planning_pins_active_v3 WHERE pin_id='55550000-0000-0000-0000-0000000000b1'$$,'eq','false',true,'P4'),
-- ---- the provenance chain fixture 16 will depend on ----
(55,17,'⭐ THE PROVENANCE CHAIN, END TO END: pin -> proposal -> feedback resolves to the ORIGINAL client note. This is the chain fixture 16 asserts; if it can break here it is decorative there.',
 $$SELECT f.note FROM public.planning_pins_v3 p
     JOIN public.feedback_proposals_v3 pr ON pr.proposal_id = p.proposal_id
     JOIN public.feedback_ledger_v3 f ON f.feedback_id = pr.feedback_ids[1]
    WHERE p.pin_id='55550000-0000-0000-0000-0000000000b1'$$,'contains','not to reduce this depth',true,'P4'),
(55,18,'The chain is bidirectional: the proposal points back at the pin it minted',
 $$SELECT applied_pin_id::text FROM public.feedback_proposals_v3 WHERE proposal_id='55550000-0000-0000-0000-0000000000a1'$$,'eq','55550000-0000-0000-0000-0000000000b1',true,'P4'),
-- ---- ACL (S-88: RLS is not the write guard, THE GRANT is) ----
(55,19,'authenticated holds SELECT and NOTHING else on all three new tables (9 privileges would mean the Supabase default grant was never revoked)',
 $$SELECT count(*)::text FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee='authenticated'
      AND table_name IN ('feedback_ledger_v3','feedback_proposals_v3','planning_pins_v3')
      AND privilege_type <> 'SELECT'$$,'eq','0',true,'P4'),
(55,20,'...and the SELECT itself survived the REVOKE (non-vacuity: seq 19 alone would pass on a table nobody can read at all)',
 $$SELECT count(*)::text FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee='authenticated' AND privilege_type='SELECT'
      AND table_name IN ('feedback_ledger_v3','feedback_proposals_v3','planning_pins_v3')$$,'eq','3',true,'P4'),
(55,21,'anon and PUBLIC hold nothing on any of the four new objects, view included',
 $$SELECT count(*)::text FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee IN ('anon','PUBLIC')
      AND table_name IN ('feedback_ledger_v3','feedback_proposals_v3','planning_pins_v3','v_planning_pins_active_v3')$$,'eq','0',true,'P4'),
(55,22,'The canonical view is security_invoker, so it cannot become an RLS bypass for the table beneath it (ADR §7)',
 $$SELECT coalesce((SELECT option_value FROM pg_options_to_table((SELECT reloptions FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='v_planning_pins_active_v3')) WHERE option_name='security_invoker'),'NOT_SET')$$,'eq','true',true,'P4'),
(55,23,'RLS is enabled on all three tables',
 $$SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relrowsecurity
      AND c.relname IN ('feedback_ledger_v3','feedback_proposals_v3','planning_pins_v3')$$,'eq','3',true,'P4'),
-- ---- LAW 4 / LAW 12 tripwires: this fixture must not touch live plan state ----
(55,24,'LAW 12 tripwire: the fixture wrote NOTHING to the live plan table on its own plan_date',
 $$SELECT count(*)::text FROM public.refill_plan_output WHERE plan_date = {{plan_date}}$$,'eq','0',true,'P4'),
(55,25,'⭐ S-124 FLEET SWEEP, not a per-date check: total refill_plan_output rows on any 2030+ date is unchanged at 21. A per-date tripwire passed for 78 legs while residue accumulated elsewhere.',
 $$SELECT count(*)::text FROM public.refill_plan_output WHERE plan_date >= DATE '2030-01-01'$$,'eq','21',true,'P4'),
(55,26,'⭐ S-124 extended: pod_refill_plan gets its own fleet sweep. A tripwire on one table is no more a sweep than a per-date check was.',
 $$SELECT count(*)::text FROM public.pod_refill_plan WHERE plan_date >= DATE '2030-01-01'$$,'eq','9',true,'P4');
