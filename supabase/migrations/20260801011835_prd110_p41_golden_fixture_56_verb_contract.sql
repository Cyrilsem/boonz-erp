-- PRD-110 P4.1 — golden fixture 56: the CONTRACT of the three feedback verbs.
--
-- LAW 1 (FIXTURE FIRST): this lands BEFORE submit_feedback_v3 /
-- propose_pin_from_feedback_v3 / approve_feedback_proposal_v3 exist, so its first
-- run is RED by construction. That red is the falsification: a fixture that is
-- green before the thing it tests was built is proving nothing (leg 79's lesson,
-- S-126's third rule).
--
-- What it pins:
--   * the provenance chain feedback -> proposal -> pin is INTACT and DERIVED, not
--     asserted by the caller (fixture 16's core claim, built one layer down);
--   * the driver channel WRAPS driver_propose_adjustment instead of restating it,
--     and RESTORES app.rpc_name afterwards (Article 4 attribution would otherwise
--     be silently wrong for every driver submission);
--   * every refusal fires by the RIGHT rule — each negative probe asserts on the
--     error TEXT, not merely on "something threw" (a WHEN OTHERS that records
--     'REFUSED' is vacuous: a typo reads the same as a working guard).
--
-- ⛔ ANCHORS ARE DELIBERATELY DISJOINT FROM FIXTURE 55. 55 leaves a live
--    always_stock pin on (m, s1, product OFFSET 1); this fixture uses products at
--    OFFSET 2/3 so the two never contend for ux_pin_v3_active_one_per_kind.
--
-- ⭐ S-117 BUILT IN, NOT DISCOVERED: the verbs mint their own uuids, so rows are
--    reclaimed by marker ('FX56%' in note / trigger_reason) rather than by id, and
--    the driver probe runs in a subtransaction that is deliberately rolled back so
--    it never accumulates rows in driver_recommendations / driver_feedback /
--    refill_edit_signals — tables this fixture has no business deleting from.

SET LOCAL statement_timeout = '120s';

DELETE FROM golden.assertions WHERE fixture_id = 56;
DELETE FROM golden.fixtures   WHERE fixture_id = 56;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes, scenario_sql)
VALUES (
  56,
  'P4.1 verb contract: submit -> propose -> approve mints a pin whose provenance is derived from its evidence, the driver channel wraps driver_propose_adjustment and restores rpc attribution, and every gate refuses by its own named rule',
  'PRD-110 P4.1 — the three tables landed in leg 79 with no writers; these are the writers',
  'P4',
  DATE '2030-01-01' + 56,
  'failing_expected',
  true,
  'Anchors use boonz_products OFFSET 2/3 to stay clear of fixture 55''s live pin. The driver probe is rolled back on purpose.',
$fixture$
-- ============================ BLOCK A — reclaim, anchor, happy path ============================
DO $fx56a$
DECLARE
  m1 uuid; m2 uuid; s1 uuid; s2 uuid; p3 uuid; p4 uuid;
  admin_uuid uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  fb_c1 uuid; fb_s1 uuid; fb_s2 uuid; fb_c2 uuid;
  fb_n1 uuid; fb_n2 uuid; fb_n3 uuid;
  pr1 uuid; pr2 uuid; pr3 uuid; pr4 uuid;
  j jsonb;
BEGIN
  -- ---- idempotent reclaim, children before parents, by marker ----
  DELETE FROM public.planning_pins_v3
   WHERE proposal_id IN (SELECT proposal_id FROM public.feedback_proposals_v3
                          WHERE trigger_reason LIKE 'FX56%')
      OR feedback_ids && COALESCE(
           (SELECT array_agg(feedback_id) FROM public.feedback_ledger_v3 WHERE note LIKE 'FX56%'),
           '{}'::uuid[]);
  DELETE FROM public.feedback_proposals_v3 WHERE trigger_reason LIKE 'FX56%';
  DELETE FROM public.feedback_ledger_v3    WHERE note LIKE 'FX56%';
  DELETE FROM golden.scratch WHERE fixture_id = 56;

  -- ---- deterministic real anchors (every FK here is RESTRICT) ----
  SELECT machine_id INTO m1 FROM public.shelf_configurations GROUP BY machine_id ORDER BY machine_id LIMIT 1;
  SELECT machine_id INTO m2 FROM public.shelf_configurations GROUP BY machine_id ORDER BY machine_id OFFSET 1 LIMIT 1;
  SELECT shelf_id   INTO s1 FROM public.shelf_configurations WHERE machine_id = m1 ORDER BY shelf_id LIMIT 1;
  SELECT shelf_id   INTO s2 FROM public.shelf_configurations WHERE machine_id = m2 ORDER BY shelf_id LIMIT 1;
  SELECT product_id INTO p3 FROM public.boonz_products ORDER BY product_id OFFSET 2 LIMIT 1;
  SELECT product_id INTO p4 FROM public.boonz_products ORDER BY product_id OFFSET 3 LIMIT 1;

  IF m2 IS NULL OR s2 IS NULL OR p4 IS NULL THEN
    RAISE EXCEPTION 'FX56 setup: anchors incomplete (m2=% s2=% p4=%) — the fixture would assert over nothing', m2, s2, p4;
  END IF;

  INSERT INTO golden.scratch(fixture_id,key,value) VALUES
    (56,'anchor_m1', to_jsonb(m1::text)), (56,'anchor_m2', to_jsonb(m2::text)),
    (56,'anchor_s1', to_jsonb(s1::text)), (56,'anchor_p3', to_jsonb(p3::text)),
    (56,'anchor_p4', to_jsonb(p4::text));

  -- ⭐ Impersonate the operator_admin so auth.uid() is REAL. Running as postgres
  --    leaves auth.uid() NULL and every role gate short-circuits — the fixture
  --    would then prove the gates exist but never that they ADMIT anyone.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

  -- ---- submit: the client and CS channels ----
  fb_c1 := (public.submit_feedback_v3('client', m1, 'dont_reduce',
              'FX56 client asked us not to reduce this depth again', s1, p3) ->> 'feedback_id')::uuid;
  INSERT INTO golden.scratch(fixture_id,key,value)
    VALUES (56,'rpc_name_after_submit', to_jsonb(current_setting('app.rpc_name', true)));

  fb_s1 := (public.submit_feedback_v3('cs', m1, 'always_stock',
              'FX56 CS standing instruction to always stock this line', s1, p4) ->> 'feedback_id')::uuid;
  fb_s2 := (public.submit_feedback_v3('cs', m1, 'never_stock',
              'FX56 CS later said never stock this same line here', s1, p4) ->> 'feedback_id')::uuid;
  fb_c2 := (public.submit_feedback_v3('client', m1, 'more_facings',
              'FX56 client wants more facings for a limited window', s1, p3) ->> 'feedback_id')::uuid;
  -- three left OPEN on purpose, as evidence for the negative propose probes
  fb_n1 := (public.submit_feedback_v3('cs', m1, 'other',
              'FX56 open evidence one, stays open for the negative probes', s1, p3) ->> 'feedback_id')::uuid;
  fb_n2 := (public.submit_feedback_v3('cs', m2, 'other',
              'FX56 open evidence two, lives on the OTHER machine', s2, p3) ->> 'feedback_id')::uuid;
  fb_n3 := (public.submit_feedback_v3('cs', m1, 'other',
              'FX56 open evidence three, same machine but a different product', s1, p4) ->> 'feedback_id')::uuid;

  INSERT INTO golden.scratch(fixture_id,key,value) VALUES
    (56,'fb_c1', to_jsonb(fb_c1::text)), (56,'fb_s1', to_jsonb(fb_s1::text)),
    (56,'fb_s2', to_jsonb(fb_s2::text)), (56,'fb_c2', to_jsonb(fb_c2::text)),
    (56,'fb_n1', to_jsonb(fb_n1::text)), (56,'fb_n2', to_jsonb(fb_n2::text)),
    (56,'fb_n3', to_jsonb(fb_n3::text));

  -- ---- propose: four proposals, targets DERIVED from the evidence ----
  pr1 := (public.propose_pin_from_feedback_v3(ARRAY[fb_c1], {{plan_date}}, 'protect_depth',
            'FX56 client depth request, cited once', 4, 'perpetual', NULL) ->> 'proposal_id')::uuid;
  pr2 := (public.propose_pin_from_feedback_v3(ARRAY[fb_s1], {{plan_date}}, 'always_stock',
            'FX56 CS standing always-stock instruction', NULL, 'perpetual', NULL) ->> 'proposal_id')::uuid;
  pr3 := (public.propose_pin_from_feedback_v3(ARRAY[fb_s2], {{plan_date}}, 'never_stock',
            'FX56 the contradicting instruction, must not be approvable', NULL, 'perpetual', NULL) ->> 'proposal_id')::uuid;
  pr4 := (public.propose_pin_from_feedback_v3(ARRAY[fb_c2], {{plan_date}}, 'min_facing',
            'FX56 time-boxed facings request, to be rejected', 3, 'until', now() + interval '30 days') ->> 'proposal_id')::uuid;

  INSERT INTO golden.scratch(fixture_id,key,value) VALUES
    (56,'pr1', to_jsonb(pr1::text)), (56,'pr2', to_jsonb(pr2::text)),
    (56,'pr3', to_jsonb(pr3::text)), (56,'pr4', to_jsonb(pr4::text));

  -- ---- approve: two mint pins, one is refused by the contradiction guard, one is rejected ----
  j := public.approve_feedback_proposal_v3(pr1, 'approve', 'FX56 approving the client depth protection');
  INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'pin1', to_jsonb(j ->> 'pin_id'));
  j := public.approve_feedback_proposal_v3(pr2, 'approve', 'FX56 approving the CS always-stock pin');
  INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'pin2', to_jsonb(j ->> 'pin_id'));
  j := public.approve_feedback_proposal_v3(pr4, 'reject',  'FX56 rejecting the facings request on purpose');
  INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'reject_status', to_jsonb(j ->> 'status'));

  -- ⛔ NO exception handler in this block, by the fixture-55 rule: a handler would
  --    roll the whole arrangement back and leave every probe below asserting over
  --    an empty table. Setup failures must be LOUD.
END
$fx56a$;

-- ============================ BLOCK B — the driver wrap, then rolled back ============================
DO $fx56b$
DECLARE
  m1 uuid; s1 uuid; p3 uuid;
  v_fb uuid; v_rec uuid; v_kind text; v_rpc_after text; v_note text; j jsonb;
BEGIN
  SELECT machine_id INTO m1 FROM public.shelf_configurations GROUP BY machine_id ORDER BY machine_id LIMIT 1;
  SELECT shelf_id   INTO s1 FROM public.shelf_configurations WHERE machine_id = m1 ORDER BY shelf_id LIMIT 1;
  SELECT product_id INTO p3 FROM public.boonz_products ORDER BY product_id OFFSET 2 LIMIT 1;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

  -- ⭐ Everything inside this sub-block is undone by the RAISE at its end. plpgsql
  --    variables SURVIVE the rollback (only DB writes are reverted), which is what
  --    lets the probe observe the wrap without leaving residue behind.
  BEGIN
    j := public.submit_feedback_v3('driver', m1, 'always_stock',
           'FX56 driver two-tap, must wrap driver_propose_adjustment', s1, p3);
    v_fb  := (j ->> 'feedback_id')::uuid;
    v_rec := (j ->> 'driver_rec_id')::uuid;

    -- Article 4: the inner call re-stamps app.rpc_name to its OWN name. If the
    -- wrapper does not restore it, every driver submission is attributed to the
    -- wrong RPC and no write-guard can tell them apart.
    v_rpc_after := current_setting('app.rpc_name', true);

    SELECT dr.kind, dr.note INTO v_kind, v_note
      FROM public.driver_recommendations dr WHERE dr.rec_id = v_rec;

    RAISE EXCEPTION 'FX56_ROLLBACK_DRIVER_PROBE';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'FX56_ROLLBACK_DRIVER_PROBE' THEN RAISE; END IF;
  END;

  INSERT INTO golden.scratch(fixture_id,key,value) VALUES
    (56,'drv_outcome',  to_jsonb(CASE WHEN v_fb IS NOT NULL AND v_rec IS NOT NULL
                                      THEN 'WRAPPED' ELSE 'NOT_WRAPPED' END)),
    (56,'drv_kind',     to_jsonb(COALESCE(v_kind,'<none>'))),
    (56,'drv_note',     to_jsonb(COALESCE(left(v_note,4),'<none>'))),
    (56,'drv_rpc_after',to_jsonb(COALESCE(v_rpc_after,'<unset>')));
END
$fx56b$;

-- ============================ BLOCK C — refusals, each by its own named rule ============================
DO $fx56c$
DECLARE
  m1 uuid; m2 uuid; s1 uuid; s2 uuid; p3 uuid; p4 uuid;
  fb_c1 uuid; fb_n1 uuid; fb_n2 uuid; fb_n3 uuid; pr1 uuid; pr3 uuid;
  admin_claims text := '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}';
BEGIN
  SELECT machine_id INTO m1 FROM public.shelf_configurations GROUP BY machine_id ORDER BY machine_id LIMIT 1;
  SELECT machine_id INTO m2 FROM public.shelf_configurations GROUP BY machine_id ORDER BY machine_id OFFSET 1 LIMIT 1;
  SELECT shelf_id   INTO s1 FROM public.shelf_configurations WHERE machine_id = m1 ORDER BY shelf_id LIMIT 1;
  SELECT shelf_id   INTO s2 FROM public.shelf_configurations WHERE machine_id = m2 ORDER BY shelf_id LIMIT 1;
  SELECT product_id INTO p3 FROM public.boonz_products ORDER BY product_id OFFSET 2 LIMIT 1;
  SELECT product_id INTO p4 FROM public.boonz_products ORDER BY product_id OFFSET 3 LIMIT 1;
  SELECT (value #>> '{}')::uuid INTO fb_c1 FROM golden.scratch WHERE fixture_id=56 AND key='fb_c1';
  SELECT (value #>> '{}')::uuid INTO fb_n1 FROM golden.scratch WHERE fixture_id=56 AND key='fb_n1';
  SELECT (value #>> '{}')::uuid INTO fb_n2 FROM golden.scratch WHERE fixture_id=56 AND key='fb_n2';
  SELECT (value #>> '{}')::uuid INTO fb_n3 FROM golden.scratch WHERE fixture_id=56 AND key='fb_n3';
  SELECT (value #>> '{}')::uuid INTO pr1   FROM golden.scratch WHERE fixture_id=56 AND key='pr1';
  SELECT (value #>> '{}')::uuid INTO pr3   FROM golden.scratch WHERE fixture_id=56 AND key='pr3';
  PERFORM set_config('request.jwt.claims', admin_claims, true);

  -- (a) a note nobody could review later
  BEGIN
    PERFORM public.submit_feedback_v3('cs', m1, 'other', 'too short', s1, p3);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_note', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_note', to_jsonb(SQLERRM));
  END;

  -- (b) a shelf that belongs to a different machine — the mis-attachment that makes a pin steer the wrong plan
  BEGIN
    PERFORM public.submit_feedback_v3('cs', m1, 'other',
      'FX56 cross machine shelf must be refused outright', s2, p3);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_shelf', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_shelf', to_jsonb(SQLERRM));
  END;

  -- (c) an unknown channel
  BEGIN
    PERFORM public.submit_feedback_v3('whatsapp', m1, 'other',
      'FX56 an unknown channel must be refused', s1, p3);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_channel', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_channel', to_jsonb(SQLERRM));
  END;

  -- (d) ⭐ THE ARTICLE 4 ROLE GATE. S-121: the harness runs as postgres and bypasses
  --     RLS, so the ONLY way to prove a role gate bites is to give auth.uid() a
  --     caller it must refuse. An unknown subject has no user_profiles row at all.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"000000ff-0000-0000-0000-0000000000ff","role":"authenticated"}', true);
  BEGIN
    PERFORM public.submit_feedback_v3('cs', m1, 'other',
      'FX56 an unknown caller must not be able to submit', s1, p3);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_role', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_role', to_jsonb(SQLERRM));
  END;
  PERFORM set_config('request.jwt.claims', admin_claims, true);

  -- (e) evidence already spent on an earlier proposal
  BEGIN
    PERFORM public.propose_pin_from_feedback_v3(ARRAY[fb_c1], {{plan_date}}, 'min_facing',
      'FX56 re-citing spent evidence must be refused', 2, 'perpetual', NULL);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_spent', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_spent', to_jsonb(SQLERRM));
  END;

  -- (f) evidence spanning two machines — a pin targets exactly one
  BEGIN
    PERFORM public.propose_pin_from_feedback_v3(ARRAY[fb_n1, fb_n2], {{plan_date}}, 'min_facing',
      'FX56 evidence spanning machines must be refused', 2, 'perpetual', NULL);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_span', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_span', to_jsonb(SQLERRM));
  END;

  -- (g) evidence that disagrees on the product — the target must be DERIVED, so it must be derivable
  BEGIN
    PERFORM public.propose_pin_from_feedback_v3(ARRAY[fb_n1, fb_n3], {{plan_date}}, 'min_facing',
      'FX56 evidence disagreeing on product must be refused', 2, 'perpetual', NULL);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_target', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_target', to_jsonb(SQLERRM));
  END;

  -- (h) always_stock carrying a value: refused by the VERB, before the table CHECK ever sees it
  BEGIN
    PERFORM public.propose_pin_from_feedback_v3(ARRAY[fb_n1], {{plan_date}}, 'always_stock',
      'FX56 always_stock with a value must be refused', 5, 'perpetual', NULL);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_value', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_value', to_jsonb(SQLERRM));
  END;

  -- (i) a proposal with no evidence at all — S-126's trap, now guarded one layer earlier
  BEGIN
    PERFORM public.propose_pin_from_feedback_v3('{}'::uuid[], {{plan_date}}, 'min_facing',
      'FX56 an evidence-free proposal must be refused', 2, 'perpetual', NULL);
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_empty', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_empty', to_jsonb(SQLERRM));
  END;

  -- (j) ⭐ THE CONTRADICTION, caught at the VERB with a readable message rather than
  --     surfacing to CS as a raw 23505 from ux_pin_v3_stock_policy_exclusive.
  BEGIN
    PERFORM public.approve_feedback_proposal_v3(pr3, 'approve',
      'FX56 approving the contradicting never_stock pin');
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_contra', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_contra', to_jsonb(SQLERRM));
  END;

  -- (k) re-deciding a decided proposal
  BEGIN
    PERFORM public.approve_feedback_proposal_v3(pr1, 'reject', 'FX56 re-deciding a settled proposal');
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_redecide', to_jsonb('ACCEPTED'::text));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch(fixture_id,key,value) VALUES (56,'neg_redecide', to_jsonb(SQLERRM));
  END;

  PERFORM set_config('request.jwt.claims', '', true);
END
$fx56c$;
$fixture$
);

-- ============================ assertions ============================
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

-- ---- submit_feedback_v3 ----
(56, 1, 'submit_feedback_v3 wrote exactly the seven ledger rows this fixture submits — a deterministic count, so a drift on re-run is a real signal (S-117)',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3 WHERE note LIKE 'FX56%'$$, 'eq', '7', 'P4'),
(56, 2, 'every submitted row is attributed to the impersonated caller: submitted_by comes from auth.uid(), never from a parameter the client could forge',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3 WHERE note LIKE 'FX56%' AND submitted_by = '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid$$, 'eq', '7', 'P4'),
(56, 3, 'non-driver channels carry NO driver_rec_id — chk_fbl_v3_driver_channel is an equivalence, so the verb must leave it NULL rather than invent one',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3 WHERE note LIKE 'FX56%' AND driver_rec_id IS NOT NULL$$, 'eq', '0', 'P4'),
(56, 4, 'the client submission landed with the channel and intent it was given',
 $$SELECT channel||'|'||intent FROM public.feedback_ledger_v3 WHERE feedback_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='fb_c1')$$, 'eq', 'client|dont_reduce', 'P4'),
(56, 5, 'Article 4: app.rpc_name is stamped with the verb''s own name for a plain submission',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='rpc_name_after_submit'$$, 'eq', 'submit_feedback_v3', 'P4'),

-- ---- propose_pin_from_feedback_v3 ----
(56, 6, 'four proposals were generated, one per approved/rejected/refused path',
 $$SELECT count(*)::text FROM public.feedback_proposals_v3 WHERE trigger_reason LIKE 'FX56%'$$, 'eq', '4', 'P4'),
(56, 7, 'proposing CONSUMES its evidence: all four cited rows moved open -> proposed and carry a triage timestamp (chk_fbl_v3_triage forces the pair)',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3 WHERE note LIKE 'FX56%' AND status='proposed' AND triaged_at IS NOT NULL$$, 'eq', '4', 'P4'),
(56, 8, 'the three uncited rows are untouched and still open — proposing must not sweep the whole machine''s feedback',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3 WHERE note LIKE 'FX56%' AND status='open' AND triaged_at IS NULL$$, 'eq', '3', 'P4'),
(56, 9, '⭐ THE TARGET IS DERIVED, NOT DECLARED: every proposal''s (machine, shelf, product) equals its evidence''s, so a caller cannot aim a pin at something nobody asked about',
 $$SELECT count(*)::text FROM public.feedback_proposals_v3 pr
    WHERE pr.trigger_reason LIKE 'FX56%'
      AND NOT EXISTS (SELECT 1 FROM public.feedback_ledger_v3 f
                       WHERE f.feedback_id = pr.feedback_ids[1]
                         AND f.machine_id = pr.machine_id
                         AND f.shelf_id IS NOT DISTINCT FROM pr.shelf_id
                         AND f.boonz_product_id = pr.boonz_product_id)$$, 'eq', '0', 'P4'),
(56, 10, 'the time-boxed proposal carries mode=until WITH an expiry — chk_fpr_v3_mode is an equivalence in both directions',
 $$SELECT pin_mode||'|'||(pin_expires_at IS NOT NULL)::text FROM public.feedback_proposals_v3 WHERE proposal_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pr4')$$, 'eq', 'until|true', 'P4'),
(56, 11, 'a fresh proposal is pending with no review stamped on it',
 $$SELECT status FROM public.feedback_proposals_v3 WHERE proposal_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pr3')$$, 'eq', 'pending', 'P4'),
(56, 12, 'the generator records WHY it fired: scoring_breakdown is populated, not left at its default empty object',
 $$SELECT count(*)::text FROM public.feedback_proposals_v3 WHERE trigger_reason LIKE 'FX56%' AND scoring_breakdown <> '{}'::jsonb$$, 'eq', '4', 'P4'),

-- ---- approve_feedback_proposal_v3 ----
(56, 13, 'approving minted exactly two pins',
 $$SELECT count(*)::text FROM public.planning_pins_v3 WHERE proposal_id IN (SELECT proposal_id FROM public.feedback_proposals_v3 WHERE trigger_reason LIKE 'FX56%')$$, 'eq', '2', 'P4'),
(56, 14, 'the minted depth pin carries the proposal''s kind, value and mode unaltered',
 $$SELECT kind||'|'||value::text||'|'||mode||'|'||source FROM public.planning_pins_v3 WHERE pin_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pin1')$$, 'eq', 'protect_depth|4|perpetual|feedback', 'P4'),
(56, 15, '⭐ THE PROVENANCE CHAIN IS CLOSED IN BOTH DIRECTIONS: pin -> proposal -> the same evidence, and proposal.applied_pin_id points back at the pin. This is fixture 16''s core claim, asserted one layer down',
 $$SELECT (p.proposal_id = pr.proposal_id AND pr.applied_pin_id = p.pin_id
           AND p.feedback_ids = pr.feedback_ids AND p.feedback_ids @> ARRAY[f.feedback_id])::text
     FROM public.planning_pins_v3 p
     JOIN public.feedback_proposals_v3 pr ON pr.proposal_id = p.proposal_id
     JOIN public.feedback_ledger_v3 f ON f.feedback_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='fb_c1')
    WHERE p.pin_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pin1')$$, 'eq', 'true', 'P4'),
(56, 16, 'Article 8: the pin names the human who approved it, taken from auth.uid()',
 $$SELECT (created_by = '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid)::text FROM public.planning_pins_v3 WHERE pin_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pin1')$$, 'eq', 'true', 'P4'),
(56, 17, 'an approved proposal is stamped approved with a reviewer, a timestamp and a note (chk_fpr_v3_review)',
 $$SELECT status||'|'||(reviewed_by IS NOT NULL)::text||'|'||(reviewed_at IS NOT NULL)::text||'|'||(review_note IS NOT NULL)::text FROM public.feedback_proposals_v3 WHERE proposal_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pr1')$$, 'eq', 'approved|true|true|true', 'P4'),
(56, 18, 'a REJECTED proposal is reviewed but mints nothing: applied_pin_id stays NULL',
 $$SELECT status||'|'||(applied_pin_id IS NULL)::text||'|'||(reviewed_at IS NOT NULL)::text FROM public.feedback_proposals_v3 WHERE proposal_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pr4')$$, 'eq', 'rejected|true|true', 'P4'),
(56, 19, 'the verb reports the decision it took',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='reject_status'$$, 'eq', 'rejected', 'P4'),
(56, 20, 'both minted pins are visible through the canonical active-pin view, which is what engines read (Article 16)',
 $$SELECT count(*)::text FROM public.v_planning_pins_active_v3 WHERE proposal_id IN (SELECT proposal_id FROM public.feedback_proposals_v3 WHERE trigger_reason LIKE 'FX56%')$$, 'eq', '2', 'P4'),

-- ---- the driver wrap ----
(56, 21, '⭐ the driver channel WRAPS driver_propose_adjustment: the submission returned both a feedback_id and the rec_id of the row that verb created',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='drv_outcome'$$, 'eq', 'WRAPPED', 'P4'),
(56, 22, 'the wrap really reached driver_recommendations, and the intent was mapped to that table''s own vocabulary rather than passed through raw (always_stock -> needs_product)',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='drv_kind'$$, 'eq', 'needs_product', 'P4'),
(56, 23, 'the driver''s own note travelled into driver_recommendations — the wrap forwards the text, it does not summarise it away',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='drv_note'$$, 'eq', 'FX56', 'P4'),
(56, 24, '⭐ ARTICLE 4 ATTRIBUTION SURVIVES THE WRAP: the inner verb re-stamps app.rpc_name to its own name, so the wrapper must restore it. Without this every driver submission is audited as driver_propose_adjustment',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='drv_rpc_after'$$, 'eq', 'submit_feedback_v3', 'P4'),
(56, 25, 'and the driver probe left NOTHING behind — it ran in a subtransaction that was rolled back, so re-running this fixture cannot accumulate rows in driver_recommendations (S-117 built in, not discovered)',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3 WHERE note LIKE 'FX56%' AND channel='driver'$$, 'eq', '0', 'P4'),

-- ---- refusals, each pinned to its own rule ----
(56, 26, 'a note too short to review later is refused, and the message says so',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_note'$$, 'contains', 'at least 10 characters', 'P4'),
(56, 27, 'a shelf on another machine is refused — the mis-attachment that would aim a pin at the wrong plan',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_shelf'$$, 'contains', 'does not belong to machine', 'P4'),
(56, 28, 'an unknown channel is refused by name',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_channel'$$, 'contains', 'is not one of', 'P4'),
(56, 29, '⭐ THE ROLE GATE BITES. A caller with no user_profiles row is refused. S-121: a fixture runs as postgres and cannot test RLS, but it CAN drive auth.uid() through request.jwt.claims, which is the only way to watch an Article 4 gate actually refuse someone',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_role'$$, 'contains', 'not permitted', 'P4'),
(56, 30, 'evidence already spent on an earlier proposal cannot be cited twice — otherwise one complaint could justify any number of pins',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_spent'$$, 'contains', 'is not open', 'P4'),
(56, 31, 'evidence spanning two machines is refused: a pin targets exactly one',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_span'$$, 'contains', 'spans', 'P4'),
(56, 32, 'evidence that disagrees on the product is refused — the target is derived, so it has to be derivable',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_target'$$, 'contains', 'does not agree', 'P4'),
(56, 33, 'always_stock carrying a value is refused by the VERB, with a sentence, rather than reaching CS as a raw check_violation from chk_fpr_v3_value',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_value'$$, 'contains', 'carry no value', 'P4'),
(56, 34, 'an evidence-free proposal is refused one layer above the CHECK that S-126 showed can go inert',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_empty'$$, 'contains', 'at least one feedback id', 'P4'),
(56, 35, '⭐ THE CONTRADICTION IS CAUGHT BY THE VERB: approving never_stock over a live always_stock names the conflicting pin instead of surfacing a bare unique_violation',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_contra'$$, 'contains', 'contradicts live pin', 'P4'),
(56, 36, 'and the refused approval changed nothing: the proposal is still pending with no pin attached',
 $$SELECT status||'|'||(applied_pin_id IS NULL)::text FROM public.feedback_proposals_v3 WHERE proposal_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=56 AND key='pr3')$$, 'eq', 'pending|true', 'P4'),
(56, 37, 'a settled proposal cannot be re-decided',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=56 AND key='neg_redecide'$$, 'contains', 'only pending', 'P4'),

-- ---- anti-vacuity ----
(56, 38, '⛔ ANTI-VACUITY: none of the refusal probes above is allowed to read ACCEPTED. Asserted as one sweep so a probe that silently starts passing cannot hide behind its neighbours',
 $$SELECT count(*)::text FROM golden.scratch WHERE fixture_id=56 AND key LIKE 'neg%' AND value #>> '{}' = 'ACCEPTED'$$, 'eq', '0', 'P4'),
(56, 39, '⛔ ANTI-VACUITY: all eleven refusal probes actually ran. A missing scratch key reads NULL and every contains-assertion above would pass over nothing',
 $$SELECT count(*)::text FROM golden.scratch WHERE fixture_id=56 AND key LIKE 'neg%'$$, 'eq', '11', 'P4'),
(56, 40, '⛔ ANTI-VACUITY: the fixture anchored on real rows and did not silently plan over an empty machine',
 $$SELECT count(*)::text FROM golden.scratch WHERE fixture_id=56 AND key LIKE 'anchor%' AND (value #>> '{}') <> ''$$, 'eq', '5', 'P4');

