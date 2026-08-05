-- PRD-110 P3.6/P4.2 / CS DECISION D-38 — EDIT WINS, LOUDLY.
--
-- CS answered: below-pin edits APPLY; the override is recorded on the line AND written to the
-- feedback ledger as pin-contradiction evidence feeding G12. Fixture 62 (20260803185605) is the
-- proof and was RED 7/11 on the bodies this migration replaces.
--
-- FIVE PARTS, ONE MIGRATION, ON PURPOSE (the S-128 removal-contract lesson): the columns, the
-- ledger vocabulary, the append-only protection, the verb that emits and the verb that accepts
-- are individually useless and individually tripwire each other. Split across units, fixture 62
-- reddens on the fix itself and the next leg bisects its own change.
--
--   1. plan_edits_v3 gains pin_floor_at_edit / pin_contradiction / pin_feedback_id (additive).
--   2. feedback_ledger_v3's intent CHECK gains 'pin_contradiction' (S-148 additive rebuild).
--   3. tg_plan_edits_v3_append_only learns to protect the three new columns.
--   4. submit_feedback_v3 accepts the ninth intent.
--   5. record_plan_edit_v3 detects the override, stamps the line, and emits the evidence.
--
-- ⛔ WHY THE FLOOR IS READ, NEVER RECOMPUTED. engine_add_pod_v3 already writes pin_floor_units /
--    pin_count / pin_binds / need_raw_no_pin onto EVERY shadow line, and record_plan_edit_v3
--    already resolves that exact base row to compute base_qty_at_edit. The edit path therefore
--    ASKS the engine what floor it applied. Re-deriving it from v_planning_pins_active_v3 would
--    put a SECOND copy of the pin ladder in a second function — the Article 16 sin D-35 retired
--    one migration ago, and precisely the guard-set divergence S-165 warns about.
--
-- ⛔ THE FLOOR IS THE TEST, NOT pin_binds. pin_binds means "the pin decided need_raw". A floor of
--    6 on a line the ladder independently took to 9 does not bind, yet an edit down to 3 is still
--    an override of live CS policy. Gating on pin_binds would silently miss that entire class.
--
-- ⛔ AND THE EDIT MUST HAVE LOWERED IT. The rule is: floor > 0 AND effective < floor AND
--    effective < base. The last clause is load-bearing — without it, a line the ENGINE already
--    left short of its floor (WH-limited, say) would be blamed on the next human who touched it,
--    and an 'add' that raises a short line toward the floor would be recorded as an override of
--    the very pin it is moving toward. D-38 is about a human going below, nothing else.
--
-- ⭐ EVIDENCE GOES THROUGH THE CANONICAL VERB. mine_edit_history_v3 already establishes the
--    pattern — submit_feedback_v3, then restore the GUCs the inner verb overwrote (fixture 56
--    seq 24). A raw INSERT into feedback_ledger_v3 would bypass the shelf-belongs-to-machine
--    check that exists precisely to stop a pin descending from a mis-addressed row.
--
-- ⭐ NEVER INVENT A SKU (D-39's standing rule). Edits are at POD grain and the ledger is at BOONZ
--    PRODUCT grain. The boonz product is attached only when the pod resolves to EXACTLY ONE
--    active mapping; 0 or 2+ resolve to NULL and the evidence still lands, machine- and
--    shelf-addressed. Guessing would poison the pin proposals this evidence feeds.

-- ---------------------------------------------------------------------------------------------
-- PART 1 — the columns. Additive, nullable-or-defaulted, no rewrite of existing rows' meaning.
-- ---------------------------------------------------------------------------------------------
-- ⛔ CODY R1: pin_contradiction is NULLABLE, deliberately. A NOT NULL DEFAULT false would
--    backfill all 178 pre-D-38 rows to "false", asserting "evaluated, no contradiction" about
--    edits that were never checked against a pin at all. That is the silent-zero LAW 5 forbids
--    and precisely the ambiguity seq 10 of fixture 62 exists to prevent.
--    NULL = written before D-38, never evaluated. true/false = evaluated. The verb always
--    computes a non-NULL value, so every row written from here on is decidable.
-- ⛔ CODY R2: ON DELETE RESTRICT, never SET NULL. SET NULL is an UPDATE against an append-only
--    table - the trigger would raise and the delete would fail anyway, so SET NULL would be a
--    declared behaviour that cannot happen. RESTRICT states the true intent (evidence is not
--    deletable) and matches every other FK on feedback_ledger_v3.
ALTER TABLE public.plan_edits_v3
  ADD COLUMN IF NOT EXISTS pin_floor_at_edit  int,
  ADD COLUMN IF NOT EXISTS pin_contradiction  boolean,
  ADD COLUMN IF NOT EXISTS pin_feedback_id    uuid REFERENCES public.feedback_ledger_v3(feedback_id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.plan_edits_v3.pin_floor_at_edit IS
  'D-38: the pin floor the ENGINE recorded on the line this edit reacted to (reasoning->>pin_floor_units). NULL = no engine line to contradict; 0 = the engine looked and found no pin. Never recomputed from the pins view.';
COMMENT ON COLUMN public.plan_edits_v3.pin_contradiction IS
  'D-38: true when this edit lowered the line below a live pin floor. The edit still applies (CS chose edit-wins-loudly); this is the loudly. NULL = the row predates D-38 and was never evaluated - never conflate that with false (Cody R1).';
COMMENT ON COLUMN public.plan_edits_v3.pin_feedback_id IS
  'D-38: the feedback_ledger_v3 row carrying this override as pin-contradiction evidence for G12.';

-- ---------------------------------------------------------------------------------------------
-- PART 2 — the ledger vocabulary. S-148 additive rebuild of a CLOSED check.
-- ---------------------------------------------------------------------------------------------
DO $part2$
DECLARE
  v_def  text;
  v_want text[] := ARRAY['dont_reduce','always_stock','never_stock','more_facings',
                         'less_facings','wrong_product','machine_issue','other'];
  v_i    text;
  v_mach uuid;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
   WHERE conrelid = 'public.feedback_ledger_v3'::regclass
     AND conname  = 'feedback_ledger_v3_intent_check';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'D-38 PART 2: feedback_ledger_v3_intent_check is absent - refusing to invent one';
  END IF;
  IF v_def LIKE '%pin_contradiction%' THEN
    RAISE NOTICE 'D-38 PART 2: already applied, skipping';
    RETURN;
  END IF;

  -- ⛔ S-148: never re-state a closed CHECK from memory. Prove every incumbent is present
  --    FIRST, so a value added by some other leg cannot be silently dropped by this rebuild.
  FOREACH v_i IN ARRAY v_want LOOP
    IF v_def NOT LIKE '%''' || v_i || '''%' THEN
      RAISE EXCEPTION 'D-38 PART 2: incumbent intent % is not in the live CHECK (%) - refusing to rebuild', v_i, v_def;
    END IF;
  END LOOP;
  IF (length(v_def) - length(replace(v_def, '''', ''))) / 2 <> 8 THEN
    RAISE EXCEPTION 'D-38 PART 2: live CHECK carries % quoted values, expected exactly 8 - refusing to rebuild (%)',
      (length(v_def) - length(replace(v_def, '''', ''))) / 2, v_def;
  END IF;

  ALTER TABLE public.feedback_ledger_v3 DROP CONSTRAINT feedback_ledger_v3_intent_check;
  ALTER TABLE public.feedback_ledger_v3 ADD CONSTRAINT feedback_ledger_v3_intent_check
    CHECK (intent = ANY (ARRAY['dont_reduce'::text, 'always_stock'::text, 'never_stock'::text,
                               'more_facings'::text, 'less_facings'::text, 'wrong_product'::text,
                               'machine_issue'::text, 'other'::text, 'pin_contradiction'::text]));

  -- ⭐ A rebuilt CHECK that refuses nothing is not a CHECK. Prove it still bites.
  SELECT machine_id INTO v_mach FROM public.machines LIMIT 1;
  BEGIN
    INSERT INTO public.feedback_ledger_v3 (channel, machine_id, intent, note)
    VALUES ('cs', v_mach, 'definitely_not_an_intent', 'refusal probe for the rebuilt intent check');
    RAISE EXCEPTION 'D-38 PART 2: the rebuilt CHECK ACCEPTED an invalid intent - aborting';
  EXCEPTION WHEN check_violation THEN
    NULL;  -- refused, as required
  END;
END $part2$;

-- ---------------------------------------------------------------------------------------------
-- PART 3 — append-only protection for the new columns.
-- ⛔ The trigger enumerates its immutable columns as an EXPLICIT tuple. A column it does not name
--    is silently UPDATE-able, so without this the pin-contradiction record could be erased after
--    the fact and "loudly" would decay straight back to "silently".
-- ---------------------------------------------------------------------------------------------
DO $part3$
DECLARE
  v_def text;
  v_new text;
  v_a1  text := E'      NEW.base_qty_at_edit, NEW.source_run_id, NEW.created_at)';
  v_a2  text := E'      OLD.base_qty_at_edit, OLD.source_run_id, OLD.created_at)';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'tg_plan_edits_v3_append_only';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'D-38 PART 3: tg_plan_edits_v3_append_only not found';
  END IF;
  IF v_def LIKE '%pin_contradiction%' THEN
    RAISE NOTICE 'D-38 PART 3: already applied, skipping';
    RETURN;
  END IF;

  -- ⭐ Count each anchor as an EXACT SUBSTRING before substituting.
  IF (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1) <> 1 THEN
    RAISE EXCEPTION 'D-38 PART 3: NEW-tuple anchor does not appear exactly once';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2) <> 1 THEN
    RAISE EXCEPTION 'D-38 PART 3: OLD-tuple anchor does not appear exactly once';
  END IF;

  v_new := replace(v_def, v_a1,
    E'      NEW.base_qty_at_edit, NEW.source_run_id, NEW.created_at,\n'
    '      NEW.pin_floor_at_edit, NEW.pin_contradiction, NEW.pin_feedback_id)');
  v_new := replace(v_new, v_a2,
    E'      OLD.base_qty_at_edit, OLD.source_run_id, OLD.created_at,\n'
    '      OLD.pin_floor_at_edit, OLD.pin_contradiction, OLD.pin_feedback_id)');

  EXECUTE v_new;
END $part3$;

-- ---------------------------------------------------------------------------------------------
-- PART 4 — submit_feedback_v3 accepts the ninth intent.
-- ---------------------------------------------------------------------------------------------
DO $part4$
DECLARE
  v_def text;
  v_new text;
  v_a   text := E'  IF p_intent IS NULL OR p_intent NOT IN (''dont_reduce'',''always_stock'',''never_stock'',\n'
                 '        ''more_facings'',''less_facings'',''wrong_product'',''machine_issue'',''other'') THEN\n'
                 '    RAISE EXCEPTION ''submit_feedback_v3: intent % is not one of the eight recorded intents'',';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'submit_feedback_v3';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'D-38 PART 4: submit_feedback_v3 not found';
  END IF;
  IF v_def LIKE '%pin_contradiction%' THEN
    RAISE NOTICE 'D-38 PART 4: already applied, skipping';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'D-38 PART 4: intent-gate anchor does not appear exactly once';
  END IF;

  v_new := replace(v_def, v_a,
    E'  -- D-38: the ninth intent. pin_contradiction is SYSTEM-generated by record_plan_edit_v3\n'
    '  --       when a human edit lands below a live pin floor. It is its own value rather than\n'
    '  --       a reuse of ''less_facings'' or ''other'' deliberately: D-40 is the standing lesson\n'
    '  --       that attaching a new signal to the nearest-looking existing one moves the system\n'
    '  --       in a direction nobody sanctioned while every count-based assertion stays green.\n'
    '  IF p_intent IS NULL OR p_intent NOT IN (''dont_reduce'',''always_stock'',''never_stock'',\n'
    '        ''more_facings'',''less_facings'',''wrong_product'',''machine_issue'',''other'',\n'
    '        ''pin_contradiction'') THEN\n'
    '    RAISE EXCEPTION ''submit_feedback_v3: intent % is not one of the nine recorded intents'',');

  EXECUTE v_new;
END $part4$;

-- ---------------------------------------------------------------------------------------------
-- PART 5 — record_plan_edit_v3 detects, stamps and emits.
-- ---------------------------------------------------------------------------------------------
DO $part5$
DECLARE
  v_def text;
  v_new text;
  v_ad  text := E'DECLARE\n  v_user_id  uuid;';
  v_ab  text := E'  -- Supersede the prior active edit on this key rather than deleting it: both';
  v_ac  text := E'    (edit_id, plan_date, machine_id, shelf_id, pod_product_id, kind, qty, "lock",\n'
                 '     author, reason, base_qty_at_edit, source_run_id)';
  v_ae  text := E'     COALESCE(p_lock,''soft''), v_user_id, btrim(p_reason), COALESCE(v_base_qty,0), v_base_run);';
  v_af  text := E'    ''base_qty_at_edit'', COALESCE(v_base_qty,0), ''source_run_id'', v_base_run,\n'
                 '    ''superseded_edit_id'', v_prior);';
  v_anch text[];
  v_one  text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_plan_edit_v3';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'D-38 PART 5: record_plan_edit_v3 not found';
  END IF;
  IF v_def LIKE '%pin_contradiction%' THEN
    RAISE NOTICE 'D-38 PART 5: already applied, skipping';
    RETURN;
  END IF;

  v_anch := ARRAY[v_ad, v_ab, v_ac, v_ae, v_af];
  FOREACH v_one IN ARRAY v_anch LOOP
    IF (length(v_def) - length(replace(v_def, v_one, ''))) / length(v_one) <> 1 THEN
      RAISE EXCEPTION 'D-38 PART 5: an anchor does not appear exactly once: %', left(v_one, 60);
    END IF;
  END LOOP;

  -- (a) new locals
  v_new := replace(v_def, v_ad,
    E'DECLARE\n'
    '  v_user_id  uuid;\n'
    '  v_pin_floor int;      -- D-38: the floor the ENGINE recorded, never recomputed here\n'
    '  v_eff_qty   int;      -- the quantity this edit leaves on the line\n'
    '  v_contra    boolean := false;\n'
    '  v_bp        uuid;     -- boonz product, only when the pod resolves unambiguously\n'
    '  v_fb        jsonb;\n'
    '  v_fb_id     uuid;');

  -- (b) read the engine's own floor + decide, immediately before the supersede block
  v_new := replace(v_new, v_ab,
    E'  -- ⭐ D-38: ASK THE ENGINE WHAT FLOOR IT APPLIED. engine_add_pod_v3 writes pin_floor_units\n'
    '  --    onto EVERY line (0 explicitly when unpinned), so this is a read, not a second copy\n'
    '  --    of the pin ladder. Recomputing from v_planning_pins_active_v3 here would be the\n'
    '  --    Article 16 duplication D-35 just retired, with S-165''s guard-set trap attached.\n'
    '  --    NULL = there was no engine line to contradict; 0 = the engine looked and found none.\n'
    '  SELECT MAX((s.reasoning->>''pin_floor_units'')::int) INTO v_pin_floor\n'
    '    FROM public.pod_refills_shadow s\n'
    '   WHERE s.run_id = v_base_run AND s.shelf_id = p_shelf_id\n'
    '     AND s.pod_product_id = p_pod_product_id;\n'
    '\n'
    '  v_eff_qty := CASE p_kind WHEN ''drop'' THEN 0\n'
    '                           WHEN ''add''  THEN COALESCE(v_base_qty,0) + COALESCE(p_qty,0)\n'
    '                           ELSE COALESCE(p_qty,0) END;\n'
    '\n'
    '  -- ⛔ THREE CLAUSES, ALL LOAD-BEARING. A floor must exist (>0); the edit must land under\n'
    '  --    it; and the edit must have LOWERED the line. Without the third, a line the engine\n'
    '  --    itself left short would be blamed on the next human to touch it, and an ''add''\n'
    '  --    moving a short line UP toward its floor would be logged as an override of that pin.\n'
    '  v_contra := COALESCE(v_pin_floor,0) > 0\n'
    '              AND v_eff_qty < v_pin_floor\n'
    '              AND v_eff_qty < COALESCE(v_base_qty,0);\n'
    '\n'
    '  IF v_contra THEN\n'
    '    -- D-39''s standing rule: never invent a SKU. Attach the boonz product only when this\n'
    '    -- pod resolves to EXACTLY ONE active mapping; otherwise the evidence lands machine-\n'
    '    -- and shelf-addressed, which is still reviewable.\n'
    '    SELECT CASE WHEN count(DISTINCT pm.boonz_product_id) = 1\n'
    '                THEN min(pm.boonz_product_id) END\n'
    '      INTO v_bp\n'
    '      FROM public.product_mapping pm\n'
    '     WHERE pm.pod_product_id = p_pod_product_id\n'
    '       AND pm.status = ''Active''\n'
    '       AND (pm.machine_id IS NULL OR pm.machine_id = v_machine)\n'
    '       AND pm.boonz_product_id IS NOT NULL;\n'
    '\n'
    '    -- Evidence through the CANONICAL verb, exactly as mine_edit_history_v3 does it: the\n'
    '    -- shelf-belongs-to-machine check inside it is what stops a pin descending later from\n'
    '    -- a mis-addressed row.\n'
    '    v_fb := public.submit_feedback_v3(\n'
    '              ''cs'', v_machine, ''pin_contradiction'',\n'
    '              ''Plan edit set this shelf to '' || v_eff_qty || '' units, below the live pin floor of ''\n'
    '                || v_pin_floor || '' recorded by the engine on '' || p_plan_date || ''. Editor reason: ''\n'
    '                || btrim(p_reason),\n'
    '              p_shelf_id, v_bp);\n'
    '    -- ⛔ the inner verb stamped app.rpc_name with its OWN name and both settings are\n'
    '    --    transaction-local (fixture 56 seq 24). Restore attribution before we write.\n'
    '    PERFORM set_config(''app.via_rpc'',  ''true'',                 true);\n'
    '    PERFORM set_config(''app.rpc_name'', ''record_plan_edit_v3'',  true);\n'
    '    v_fb_id := (v_fb ->> ''feedback_id'')::uuid;\n'
    '    IF v_fb_id IS NULL THEN\n'
    '      RAISE EXCEPTION ''record_plan_edit_v3: submit_feedback_v3 returned no feedback_id (%)'', v_fb;\n'
    '    END IF;\n'
    '  END IF;\n'
    '\n'
    '  -- Supersede the prior active edit on this key rather than deleting it: both');

  -- (c) + (d) carry it onto the line
  v_new := replace(v_new, v_ac,
    E'    (edit_id, plan_date, machine_id, shelf_id, pod_product_id, kind, qty, "lock",\n'
    '     author, reason, base_qty_at_edit, source_run_id,\n'
    '     pin_floor_at_edit, pin_contradiction, pin_feedback_id)');
  v_new := replace(v_new, v_ae,
    E'     COALESCE(p_lock,''soft''), v_user_id, btrim(p_reason), COALESCE(v_base_qty,0), v_base_run,\n'
    '     v_pin_floor, v_contra, v_fb_id);');

  -- (e) and tell the caller, so the FE can say it out loud
  v_new := replace(v_new, v_af,
    E'    ''base_qty_at_edit'', COALESCE(v_base_qty,0), ''source_run_id'', v_base_run,\n'
    '    ''pin_floor_at_edit'', v_pin_floor, ''pin_contradiction'', v_contra,\n'
    '    ''pin_feedback_id'', v_fb_id,\n'
    '    ''superseded_edit_id'', v_prior);');

  EXECUTE v_new;
END $part5$;

-- ---------------------------------------------------------------------------------------------
-- POST-APPLY ASSERTIONS (S-163): shape, not just behaviour.
-- ---------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='plan_edits_v3'
     AND column_name IN ('pin_floor_at_edit','pin_contradiction','pin_feedback_id');
  IF v_n <> 3 THEN RAISE EXCEPTION 'D-38 VERIFY: expected 3 new columns, found %', v_n; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid='public.feedback_ledger_v3'::regclass
                    AND conname='feedback_ledger_v3_intent_check'
                    AND pg_get_constraintdef(oid) LIKE '%pin_contradiction%') THEN
    RAISE EXCEPTION 'D-38 VERIFY: intent CHECK does not carry pin_contradiction';
  END IF;

  -- ⛔ S-163 / the 13-day driver-confirm outage: a CREATE OR REPLACE that silently drops
  --    defaulted arguments breaks every caller that relied on them. submit_feedback_v3 carries
  --    TWO defaults and record_plan_edit_v3 carries NONE - assert the real numbers, not a
  --    convenient uniform zero. ⭐ S-140: read the WHOLE ACL back, and the pinned search_path.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.proname='record_plan_edit_v3'
         AND p.prosecdef AND p.pronargdefaults = 0
         AND p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
         AND p.proconfig::text = '{"search_path=public, pg_temp"}'
         AND pg_get_function_identity_arguments(p.oid)
             = 'p_plan_date date, p_shelf_id uuid, p_pod_product_id uuid, p_kind text, p_qty integer, p_lock text, p_reason text') <> 1 THEN
    RAISE EXCEPTION 'D-38 VERIFY: record_plan_edit_v3 shape/ACL/search_path changed';
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.proname='submit_feedback_v3'
         AND p.prosecdef AND p.pronargdefaults = 2
         AND p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
         AND p.proconfig::text = '{"search_path=public, pg_temp"}') <> 1 THEN
    RAISE EXCEPTION 'D-38 VERIFY: submit_feedback_v3 shape/ACL/search_path changed';
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.proname='tg_plan_edits_v3_append_only'
         AND NOT p.prosecdef
         AND p.proacl::text = '{=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}') <> 1 THEN
    RAISE EXCEPTION 'D-38 VERIFY: tg_plan_edits_v3_append_only shape/ACL changed';
  END IF;

  IF (SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.proname='tg_plan_edits_v3_append_only')
     NOT LIKE '%pin_contradiction%' THEN
    RAISE EXCEPTION 'D-38 VERIFY: append-only trigger does not protect the new columns';
  END IF;
END $verify$;
