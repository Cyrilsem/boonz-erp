SET LOCAL statement_timeout = '120s';

-- ============================================================================
-- PRD-110 P4.1 — the three feedback verbs. LAW 1: proved by golden fixture 56
-- (migration 20260801011835), which was RED at 4/41 before this file.
--
-- Leg 79 landed feedback_ledger_v3 / feedback_proposals_v3 / planning_pins_v3
-- with `authenticated` holding SELECT only and NO writers, so the tables were
-- inert. These are the writers, and they are the ONLY way a row may enter.
--
-- Article 4 is binding on all three: app.via_rpc + app.rpc_name are stamped, and
-- the caller is validated by joining user_profiles on auth.uid() — never off
-- auth.jwt() claims, which the client controls.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) submit_feedback_v3 — the single door into the ledger.
--
-- ⭐ The driver channel WRAPS driver_propose_adjustment rather than restating it.
--    That function already writes driver_recommendations, driver_feedback and
--    refill_edit_signals; duplicating those writes would give the same event two
--    independent records that immediately drift. feedback_ledger_v3.driver_rec_id
--    exists precisely so the wrap is traceable, and chk_fbl_v3_driver_channel is
--    an equivalence, so the DDL itself forbids a driver row without one.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_feedback_v3(
  p_channel           text,
  p_machine_id        uuid,
  p_intent            text,
  p_note              text,
  p_shelf_id          uuid DEFAULT NULL,
  p_boonz_product_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid        uuid;
  v_role       text;
  v_allowed    text[];
  v_shelf_mach uuid;
  v_drv_kind   text;
  v_inner      jsonb;
  v_rec_id     uuid;
  v_feedback   uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                true);
  PERFORM set_config('app.rpc_name', 'submit_feedback_v3',  true);

  IF p_channel IS NULL OR p_channel NOT IN ('driver','client','cs','miner') THEN
    RAISE EXCEPTION 'submit_feedback_v3: channel % is not one of driver/client/cs/miner',
      COALESCE(p_channel,'<null>');
  END IF;
  IF p_intent IS NULL OR p_intent NOT IN ('dont_reduce','always_stock','never_stock',
        'more_facings','less_facings','wrong_product','machine_issue','other') THEN
    RAISE EXCEPTION 'submit_feedback_v3: intent % is not one of the eight recorded intents',
      COALESCE(p_intent,'<null>');
  END IF;
  -- Feedback nobody can read back is feedback nobody can act on, and the ledger
  -- CHECK would refuse it anyway - refuse it here with a sentence instead.
  IF p_note IS NULL OR char_length(btrim(p_note)) < 10 THEN
    RAISE EXCEPTION 'submit_feedback_v3: note must be at least 10 characters (got %)',
      COALESCE(char_length(btrim(p_note)), 0);
  END IF;

  -- ---- Article 4 role gate. Per-channel, because these are different actors. ----
  v_allowed := CASE p_channel
    WHEN 'driver' THEN ARRAY['field_staff','warehouse','operator_admin','superadmin','manager']
    WHEN 'miner'  THEN ARRAY['operator_admin','superadmin']
    ELSE               ARRAY['operator_admin','superadmin','manager']
  END;
  v_uid := auth.uid();
  IF v_uid IS NOT NULL THEN
    SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_uid;
    IF v_role IS NULL OR NOT (v_role = ANY (v_allowed)) THEN
      RAISE EXCEPTION 'submit_feedback_v3: caller % with role % is not permitted on channel %',
        v_uid, COALESCE(v_role,'<none>'), p_channel;
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.machines m WHERE m.machine_id = p_machine_id) THEN
    RAISE EXCEPTION 'submit_feedback_v3: machine % not found', p_machine_id;
  END IF;

  -- ⛔ A shelf on the wrong machine is the quiet failure that matters: the pin
  --    that eventually descends from this row would steer a plan nobody complained
  --    about. The FK alone cannot catch it - both rows are perfectly valid.
  IF p_shelf_id IS NOT NULL THEN
    SELECT sc.machine_id INTO v_shelf_mach
      FROM public.shelf_configurations sc WHERE sc.shelf_id = p_shelf_id;
    IF v_shelf_mach IS NULL THEN
      RAISE EXCEPTION 'submit_feedback_v3: shelf % not found', p_shelf_id;
    END IF;
    IF v_shelf_mach <> p_machine_id THEN
      RAISE EXCEPTION 'submit_feedback_v3: shelf % does not belong to machine % (it is on %)',
        p_shelf_id, p_machine_id, v_shelf_mach;
    END IF;
  END IF;

  -- ---- the driver two-tap: wrap, never restate ----
  IF p_channel = 'driver' THEN
    -- driver_recommendations speaks its own five-value vocabulary; the eight
    -- planning intents fold onto it. Mapping here keeps the ledger expressive
    -- without teaching the older table new words.
    v_drv_kind := CASE p_intent
      WHEN 'dont_reduce'   THEN 'needs_product'
      WHEN 'always_stock'  THEN 'needs_product'
      WHEN 'more_facings'  THEN 'needs_product'
      WHEN 'never_stock'   THEN 'overstocked'
      WHEN 'less_facings'  THEN 'overstocked'
      WHEN 'wrong_product' THEN 'wrong_product'
      WHEN 'machine_issue' THEN 'machine_issue'
      ELSE 'other'
    END;

    v_inner  := public.driver_propose_adjustment(
                  p_machine_id, v_drv_kind, btrim(p_note), p_boonz_product_id, p_shelf_id);
    v_rec_id := (v_inner ->> 'rec_id')::uuid;
    IF v_rec_id IS NULL THEN
      RAISE EXCEPTION 'submit_feedback_v3: driver_propose_adjustment returned no rec_id (%)', v_inner;
    END IF;

    -- ⛔ RESTORE THE ATTRIBUTION. The inner verb stamps app.rpc_name with its OWN
    --    name, and both settings are transaction-local, so without this every
    --    driver submission - and anything else writing later in the same
    --    transaction - is audited as driver_propose_adjustment. Pinned by
    --    fixture 56 seq 24.
    PERFORM set_config('app.via_rpc',  'true',               true);
    PERFORM set_config('app.rpc_name', 'submit_feedback_v3', true);
  END IF;

  INSERT INTO public.feedback_ledger_v3
    (channel, driver_rec_id, machine_id, shelf_id, boonz_product_id, intent, note, submitted_by)
  VALUES
    (p_channel, v_rec_id, p_machine_id, p_shelf_id, p_boonz_product_id,
     p_intent, btrim(p_note), v_uid)
  RETURNING feedback_id INTO v_feedback;

  RETURN jsonb_build_object(
    'status','ok', 'feedback_id', v_feedback, 'channel', p_channel,
    'driver_rec_id', v_rec_id, 'machine_id', p_machine_id, 'shelf_id', p_shelf_id,
    'boonz_product_id', p_boonz_product_id, 'intent', p_intent,
    'submitted_by', v_uid, 'wrapped_driver_verb', (p_channel = 'driver'));
END
$function$;

-- ----------------------------------------------------------------------------
-- 2) propose_pin_from_feedback_v3 — the gated generator.
--
-- ⭐ THE TARGET IS DERIVED FROM THE EVIDENCE, NOT PASSED IN. A caller supplies
--    only the feedback ids and the shape of the pin; machine/shelf/product come
--    off the cited rows. That is what makes the provenance chain load-bearing
--    rather than decorative: a proposal cannot aim somewhere nobody complained
--    about, and fixture 16's "provenance intact" claim becomes a property of the
--    verb instead of a convention.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.propose_pin_from_feedback_v3(
  p_feedback_ids    uuid[],
  p_plan_date       date,
  p_pin_kind        text,
  p_trigger_reason  text,
  p_pin_value       int         DEFAULT NULL,
  p_pin_mode        text        DEFAULT 'perpetual',
  p_pin_expires_at  timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid          uuid;
  v_ids          uuid[];
  v_missing      text;
  v_not_open     text;
  v_n_machine    int;
  v_n_product    int;
  v_n_shelf      int;
  v_n_null_prod  int;
  v_machine      uuid;
  v_product      uuid;
  v_shelf        uuid;
  v_shelf_scope  text;
  v_channels     text;
  v_intents      text;
  v_superseded   int := 0;
  v_conflict     uuid;
  v_proposal     uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                          true);
  PERFORM set_config('app.rpc_name', 'propose_pin_from_feedback_v3',  true);

  v_uid := auth.uid();
  IF v_uid IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_uid AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: caller % is not permitted to generate proposals', v_uid;
  END IF;

  -- ⭐ S-126 one layer up: chk_fpr_v3_evidence is the backstop, but a caller
  --    deserves a sentence, and the CHECK is exactly the one that shipped inert.
  --    De-duplicate too - citing the same complaint three times is not three
  --    pieces of evidence.
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_ids
    FROM unnest(COALESCE(p_feedback_ids,'{}'::uuid[])) AS x WHERE x IS NOT NULL;
  IF v_ids IS NULL OR cardinality(v_ids) < 1 THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: at least one feedback id is required';
  END IF;
  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: plan_date is required';
  END IF;
  IF p_trigger_reason IS NULL OR char_length(btrim(p_trigger_reason)) < 10 THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: trigger_reason must be at least 10 characters';
  END IF;

  IF p_pin_kind IS NULL OR p_pin_kind NOT IN ('min_facing','protect_depth','always_stock','never_stock') THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: pin_kind % is not one of min_facing/protect_depth/always_stock/never_stock',
      COALESCE(p_pin_kind,'<null>');
  END IF;
  IF p_pin_kind IN ('min_facing','protect_depth') AND (p_pin_value IS NULL OR p_pin_value < 1) THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: % requires a value of at least 1 (got %)',
      p_pin_kind, COALESCE(p_pin_value::text,'<null>');
  END IF;
  IF p_pin_kind IN ('always_stock','never_stock') AND p_pin_value IS NOT NULL THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: always_stock and never_stock carry no value (got %)', p_pin_value;
  END IF;
  IF COALESCE(p_pin_mode,'perpetual') NOT IN ('perpetual','until') THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: pin_mode % is not one of perpetual/until', p_pin_mode;
  END IF;
  IF p_pin_mode = 'until' AND (p_pin_expires_at IS NULL OR p_pin_expires_at <= now()) THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: mode until needs an expiry in the future (got %)',
      COALESCE(p_pin_expires_at::text,'<null>');
  END IF;
  IF COALESCE(p_pin_mode,'perpetual') = 'perpetual' AND p_pin_expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: a perpetual pin carries no expiry';
  END IF;

  -- ---- the evidence must exist, be unspent, and agree on one target ----
  SELECT string_agg(x::text, ', ') INTO v_missing
    FROM unnest(v_ids) AS x
   WHERE NOT EXISTS (SELECT 1 FROM public.feedback_ledger_v3 f WHERE f.feedback_id = x);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: feedback % was not found', v_missing;
  END IF;

  -- ⛔ Evidence is spent when it is cited. Without this one complaint could justify
  --    any number of pins, and the acceptance-rate telemetry of P4.3 would be
  --    measuring the same row over and over.
  SELECT string_agg(f.feedback_id::text || ' (' || f.status || ')', ', ') INTO v_not_open
    FROM public.feedback_ledger_v3 f
   WHERE f.feedback_id = ANY (v_ids) AND f.status <> 'open';
  IF v_not_open IS NOT NULL THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: feedback % is not open', v_not_open;
  END IF;

  -- ⛔ array_agg(DISTINCT ...)[1], not min(): min/max are not defined for uuid on
  --    every server version, and this must not depend on that.
  SELECT count(DISTINCT f.machine_id),
         count(DISTINCT f.boonz_product_id),
         count(DISTINCT COALESCE(f.shelf_id, '00000000-0000-0000-0000-000000000000'::uuid)),
         count(*) FILTER (WHERE f.boonz_product_id IS NULL),
         (array_agg(DISTINCT f.machine_id))[1],
         (array_agg(DISTINCT f.boonz_product_id))[1],
         (array_agg(DISTINCT COALESCE(f.shelf_id, '00000000-0000-0000-0000-000000000000'::uuid)))[1],
         string_agg(DISTINCT f.channel, '+' ORDER BY f.channel),
         string_agg(DISTINCT f.intent,  '+' ORDER BY f.intent)
    INTO v_n_machine, v_n_product, v_n_shelf, v_n_null_prod, v_machine, v_product, v_shelf, v_channels, v_intents
    FROM public.feedback_ledger_v3 f
   WHERE f.feedback_id = ANY (v_ids);
  v_shelf := NULLIF(v_shelf, '00000000-0000-0000-0000-000000000000'::uuid);

  IF v_n_machine > 1 THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: evidence spans % machines; a pin targets exactly one', v_n_machine;
  END IF;
  -- ⛔ count(DISTINCT) IGNORES NULLS, so one product plus two product-less rows
  --    counts as agreement. The NULL tally is what makes this a real check.
  IF v_n_product <> 1 OR v_n_null_prod > 0 OR v_product IS NULL THEN
    RAISE EXCEPTION 'propose_pin_from_feedback_v3: evidence does not agree on one boonz_product_id (% distinct, % without a product)',
      v_n_product, v_n_null_prod;
  END IF;
  -- Shelves are allowed to disagree: several shelf complaints about one product on
  -- one machine legitimately generalise to a machine-wide pin. Recorded, not guessed.
  IF v_n_shelf > 1 THEN
    v_shelf := NULL;
    v_shelf_scope := 'machine_wide_generalised_from_' || v_n_shelf::text || '_shelves';
  ELSE
    v_shelf_scope := CASE WHEN v_shelf IS NULL THEN 'machine_wide_as_submitted' ELSE 'shelf_specific' END;
  END IF;

  -- ---- one pending proposal per (target, kind): retire the predecessor ----
  UPDATE public.feedback_proposals_v3 pr
     SET status = 'superseded'
   WHERE pr.status = 'pending'
     AND pr.machine_id = v_machine
     AND pr.shelf_id IS NOT DISTINCT FROM v_shelf
     AND pr.boonz_product_id = v_product
     AND pr.pin_kind = p_pin_kind;
  GET DIAGNOSTICS v_superseded = ROW_COUNT;

  -- A contradiction is flagged here but NOT refused here: CS may well intend to
  -- flip a standing rule. The refusal belongs at approve, where the pin is minted.
  IF p_pin_kind IN ('always_stock','never_stock') THEN
    SELECT p.pin_id INTO v_conflict
      FROM public.planning_pins_v3 p
     WHERE p.revoked_at IS NULL
       AND p.machine_id = v_machine
       AND p.shelf_id IS NOT DISTINCT FROM v_shelf
       AND p.boonz_product_id = v_product
       AND p.kind IN ('always_stock','never_stock')
       AND p.kind <> p_pin_kind
     LIMIT 1;
  END IF;

  INSERT INTO public.feedback_proposals_v3
    (plan_date, machine_id, shelf_id, boonz_product_id, pin_kind, pin_value,
     pin_mode, pin_expires_at, feedback_ids, trigger_reason, scoring_breakdown)
  VALUES
    (p_plan_date, v_machine, v_shelf, v_product, p_pin_kind, p_pin_value,
     COALESCE(p_pin_mode,'perpetual'), p_pin_expires_at, v_ids, btrim(p_trigger_reason),
     jsonb_build_object(
       'evidence_count',      cardinality(v_ids),
       'evidence_channels',   v_channels,
       'evidence_intents',    v_intents,
       'target_derivation',   'derived_from_evidence',
       'shelf_scope',         v_shelf_scope,
       'superseded_pending',  v_superseded,
       'contradicts_live_pin', v_conflict,
       'proposed_by',         v_uid))
  RETURNING proposal_id INTO v_proposal;

  UPDATE public.feedback_ledger_v3 f
     SET status      = 'proposed',
         triaged_at  = now(),
         triage_note = 'cited by proposal ' || v_proposal::text
   WHERE f.feedback_id = ANY (v_ids);

  RETURN jsonb_build_object(
    'status','ok', 'proposal_id', v_proposal, 'plan_date', p_plan_date,
    'machine_id', v_machine, 'shelf_id', v_shelf, 'boonz_product_id', v_product,
    'pin_kind', p_pin_kind, 'pin_value', p_pin_value,
    'pin_mode', COALESCE(p_pin_mode,'perpetual'), 'pin_expires_at', p_pin_expires_at,
    'evidence_count', cardinality(v_ids), 'shelf_scope', v_shelf_scope,
    'superseded_pending', v_superseded, 'contradicts_live_pin', v_conflict);
END
$function$;

-- ----------------------------------------------------------------------------
-- 3) approve_feedback_proposal_v3 — the CS gate, and the only minter of pins.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_feedback_proposal_v3(
  p_proposal_id  uuid,
  p_decision     text,
  p_review_note  text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid       uuid;
  pr          public.feedback_proposals_v3%ROWTYPE;
  v_conflict  uuid;
  v_conf_kind text;
  v_prior     uuid;
  v_pin       uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                           true);
  PERFORM set_config('app.rpc_name', 'approve_feedback_proposal_v3',   true);

  v_uid := auth.uid();
  IF v_uid IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_uid AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'approve_feedback_proposal_v3: caller % is not permitted to decide proposals', v_uid;
  END IF;

  IF p_decision IS NULL OR p_decision NOT IN ('approve','reject') THEN
    RAISE EXCEPTION 'approve_feedback_proposal_v3: decision % is not one of approve/reject',
      COALESCE(p_decision,'<null>');
  END IF;
  IF p_review_note IS NULL OR char_length(btrim(p_review_note)) < 10 THEN
    RAISE EXCEPTION 'approve_feedback_proposal_v3: review_note must be at least 10 characters';
  END IF;

  SELECT * INTO pr FROM public.feedback_proposals_v3
   WHERE proposal_id = p_proposal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approve_feedback_proposal_v3: proposal % not found', p_proposal_id;
  END IF;
  IF pr.status <> 'pending' THEN
    RAISE EXCEPTION 'approve_feedback_proposal_v3: proposal % is already %; only pending proposals can be decided',
      p_proposal_id, pr.status;
  END IF;

  IF p_decision = 'reject' THEN
    UPDATE public.feedback_proposals_v3
       SET status = 'rejected', reviewed_by = v_uid, reviewed_at = now(),
           review_note = btrim(p_review_note)
     WHERE proposal_id = p_proposal_id;
    RETURN jsonb_build_object('status','rejected', 'proposal_id', p_proposal_id,
      'pin_id', NULL, 'reviewed_by', v_uid);
  END IF;

  -- ---- approve ----
  -- ⛔ THE GUARD MUST MATCH THE INDEX, NOT THE VIEW. ux_pin_v3_stock_policy_exclusive
  --    is partial on `revoked_at IS NULL`, while v_planning_pins_active_v3 also hides
  --    EXPIRED pins. An expired-but-unrevoked never_stock is invisible in the view and
  --    still occupies the uniqueness slot, so checking the view here would let this
  --    reach the index and surface to CS as a bare 23505.
  IF pr.pin_kind IN ('always_stock','never_stock') THEN
    SELECT p.pin_id, p.kind INTO v_conflict, v_conf_kind
      FROM public.planning_pins_v3 p
     WHERE p.revoked_at IS NULL
       AND p.machine_id = pr.machine_id
       AND p.shelf_id IS NOT DISTINCT FROM pr.shelf_id
       AND p.boonz_product_id = pr.boonz_product_id
       AND p.kind IN ('always_stock','never_stock')
       AND p.kind <> pr.pin_kind
     LIMIT 1;
    IF v_conflict IS NOT NULL THEN
      RAISE EXCEPTION 'approve_feedback_proposal_v3: contradicts live pin % (%) on the same target; revoke it first',
        v_conflict, v_conf_kind;
    END IF;
  END IF;

  -- A newer approved pin of the SAME kind supersedes its predecessor rather than
  -- colliding with it. The old row stays - revoked, attributed, readable - which is
  -- what answers "what constrained the plan on <date>?" later.
  SELECT p.pin_id INTO v_prior
    FROM public.planning_pins_v3 p
   WHERE p.revoked_at IS NULL
     AND p.machine_id = pr.machine_id
     AND p.shelf_id IS NOT DISTINCT FROM pr.shelf_id
     AND p.boonz_product_id = pr.boonz_product_id
     AND p.kind = pr.pin_kind
   FOR UPDATE;

  IF v_prior IS NOT NULL THEN
    -- chk_pin_v3_revoke demands a named revoker for any reason other than
    -- 'expired_system'. Article 8: if nobody is identified, nobody may retire a
    -- standing rule - so refuse rather than launder it as a system expiry.
    IF v_uid IS NULL THEN
      RAISE EXCEPTION 'approve_feedback_proposal_v3: cannot supersede live pin % without an identified caller', v_prior;
    END IF;
    -- ⛔ ORDER IS LOAD-BEARING: ux_pin_v3_active_one_per_kind admits one live pin
    --    per (target, kind), so the predecessor is retired BEFORE the successor is
    --    inserted. Insert-first raises 23505 every time.
    UPDATE public.planning_pins_v3
       SET revoked_at = now(), revoked_by = v_uid,
           revoke_reason = 'superseded_by_proposal ' || p_proposal_id::text
     WHERE pin_id = v_prior;
  END IF;

  INSERT INTO public.planning_pins_v3
    (machine_id, shelf_id, boonz_product_id, kind, value, mode, expires_at,
     source, feedback_ids, proposal_id, created_by)
  VALUES
    (pr.machine_id, pr.shelf_id, pr.boonz_product_id, pr.pin_kind, pr.pin_value,
     pr.pin_mode, pr.pin_expires_at, 'feedback', pr.feedback_ids, p_proposal_id, v_uid)
  RETURNING pin_id INTO v_pin;

  UPDATE public.feedback_proposals_v3
     SET status = 'approved', reviewed_by = v_uid, reviewed_at = now(),
         review_note = btrim(p_review_note), applied_pin_id = v_pin
   WHERE proposal_id = p_proposal_id;

  RETURN jsonb_build_object(
    'status','approved', 'proposal_id', p_proposal_id, 'pin_id', v_pin,
    'machine_id', pr.machine_id, 'shelf_id', pr.shelf_id,
    'boonz_product_id', pr.boonz_product_id, 'kind', pr.pin_kind,
    'value', pr.pin_value, 'mode', pr.pin_mode, 'expires_at', pr.pin_expires_at,
    'superseded_pin_id', v_prior, 'reviewed_by', v_uid);
END
$function$;

-- ---- ACL: the v3 fleet convention (S-104 / S-81). No anon, no PUBLIC. ----
REVOKE ALL ON FUNCTION public.submit_feedback_v3(text,uuid,text,text,uuid,uuid)                       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.propose_pin_from_feedback_v3(uuid[],date,text,text,int,text,timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.approve_feedback_proposal_v3(uuid,text,text)                             FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.submit_feedback_v3(text,uuid,text,text,uuid,uuid)                       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.propose_pin_from_feedback_v3(uuid[],date,text,text,int,text,timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_feedback_proposal_v3(uuid,text,text)                             TO authenticated, service_role;

COMMENT ON FUNCTION public.submit_feedback_v3(text,uuid,text,text,uuid,uuid) IS
  'PRD-110 P4.1. The only writer of feedback_ledger_v3. Driver channel WRAPS driver_propose_adjustment and restores app.rpc_name afterwards. Proved by golden fixture 56.';
COMMENT ON FUNCTION public.propose_pin_from_feedback_v3(uuid[],date,text,text,int,text,timestamptz) IS
  'PRD-110 P4.1. The only writer of feedback_proposals_v3. Target (machine/shelf/product) is DERIVED from the cited evidence, never passed in; evidence is spent on citation. Proved by golden fixture 56.';
COMMENT ON FUNCTION public.approve_feedback_proposal_v3(uuid,text,text) IS
  'PRD-110 P4.1. The only minter of planning_pins_v3. Refuses always/never contradictions by name, supersedes a same-kind predecessor by revoking it first. Proved by golden fixture 56.';

-- The fixture is no longer expected to fail: its subject now exists.
UPDATE golden.fixtures SET baseline_status = 'passing' WHERE fixture_id = 56;
