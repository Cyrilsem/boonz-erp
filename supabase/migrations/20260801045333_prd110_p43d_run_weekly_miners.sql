-- PRD-110 P4.3d — run_weekly_miners_v3, the weekly wrapper the cron calls
-- Dara design + Cody review (leg 89).
-- Articles: 4 (SECURITY DEFINER, justified below + search_path pinned),
--           7 (writes only its own append-only log), 12 (forward-only).
--
-- WHY A WRAPPER RATHER THAN LOGGING INSIDE EACH MINER: the miners are proven
-- objects (fixtures 57 and 58, engine md5s pinned by assertions). Teaching each
-- of them to log would rewrite two proven prosrc bodies for a concern that is
-- not theirs. The wrapper is additive and neither miner changes by one byte.
-- The cost is honest and recorded: a miner invoked DIRECTLY leaves no
-- miner_runs_v3 row. This log answers "what did the schedule find", not
-- "every time anyone ever ran a miner".

--------------------------------------------------- (1) the tally, in pure ----
-- Pure and data-free on purpose: every branch is testable without running a
-- miner or planting a proposal (the g12_verdict_v3 shape, leg 88).
CREATE OR REPLACE FUNCTION public.miner_refusal_tally_v3(p_codes text[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('code', c.code, 'n', c.n)
                      ORDER BY c.n DESC, c.code)
       FROM (SELECT x AS code, count(*)::int AS n
               FROM unnest(COALESCE(p_codes, '{}'::text[])) AS x
              WHERE x IS NOT NULL
              GROUP BY x) c),
    '[]'::jsonb);
$$;

COMMENT ON FUNCTION public.miner_refusal_tally_v3(text[]) IS
  'PRD-110 P4.3d. Tallies miner refusal codes into [{code,n}] ordered by n DESC. Returns [] for NULL or empty input - a run with nothing to refuse and a run whose refusals were lost must not look the same, so the empty array is explicit.';

REVOKE ALL ON FUNCTION public.miner_refusal_tally_v3(text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.miner_refusal_tally_v3(text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.miner_refusal_tally_v3(text[]) TO authenticated, service_role;

------------------------------------------------------------ (2) the runner ---
CREATE OR REPLACE FUNCTION public.run_weekly_miners_v3(
  p_invoked_by   text    DEFAULT 'cron',
  p_pick_dry_run boolean DEFAULT NULL,
  p_edit_dry_run boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_batch    uuid := gen_random_uuid();
  v_pick_dry boolean;
  v_edit_dry boolean;
  v_epoch    date;
  v_warn     text[] := '{}'::text[];   -- batch-level, for the return value
  v_row_warn text[];                   -- only the warnings that bind THIS miner
  v_synth    int;
  v_miner    text;
  v_dry      boolean;
  v_t0       timestamptz;
  v_t1       timestamptz;
  v_payload  jsonb;
  v_status   text;
  v_err      text;
  v_state    text;
  v_created  int;
  v_would    int;
  v_codes    text[];
  v_run_id   uuid;
  v_out      jsonb := '[]'::jsonb;
BEGIN
  -- ⛔ Validate before the dials are read: an unrecognised invoked_by would be
  --    caught by the CHECK constraint anyway, but only AFTER both miners had
  --    run. Refuse first; a live miner must not run for a call that cannot log.
  IF p_invoked_by IS NULL OR p_invoked_by NOT IN ('cron','manual','fixture') THEN
    RAISE EXCEPTION 'run_weekly_miners_v3: p_invoked_by must be one of cron|manual|fixture, got %',
      COALESCE(p_invoked_by, 'NULL');
  END IF;

  -- ⛔ Cody, Article 4: the dry-run dials are the parked CS decision. A caller
  --    who may pass p_*_dry_run => false can mint live proposals AROUND that
  --    decision, which would make the dial decoration. EXECUTE is granted to
  --    service_role only, and this branch keeps the hole shut if that grant is
  --    ever widened. A NULL auth.uid() is the cron / postgres / harness path.
  IF (p_pick_dry_run IS NOT NULL OR p_edit_dry_run IS NOT NULL)
     AND (SELECT auth.uid()) IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.user_profiles up
                      WHERE up.id = (SELECT auth.uid())
                        AND up.role = ANY (ARRAY['operator_admin','superadmin']))
  THEN
    RAISE EXCEPTION 'run_weekly_miners_v3: overriding the dry-run dials requires operator_admin or superadmin - the dials are a parked CS decision, not a default';
  END IF;

  SELECT r.miner_weekly_pick_dry_run, r.miner_weekly_edit_dry_run, r.miner_fixture_epoch
    INTO v_pick_dry, v_edit_dry, v_epoch
    FROM public.refill_policy_params r
   ORDER BY r.id            -- ⛔ one row by convention, not by structure (S-138)
   LIMIT 1;

  -- ⛔ NEVER default a missing dial to "may mint". A params table with no row
  --    is a broken deployment, not permission.
  IF v_pick_dry IS NULL OR v_edit_dry IS NULL OR v_epoch IS NULL THEN
    RAISE EXCEPTION 'run_weekly_miners_v3: refill_policy_params holds no dial row - refusing to guess whether a miner may mint live proposals';
  END IF;

  v_pick_dry := COALESCE(p_pick_dry_run, v_pick_dry);
  v_edit_dry := COALESCE(p_edit_dry_run, v_edit_dry);

  -- The environment check. A pending proposal dated in the synthetic universe
  -- occupies the GLOBAL one-pending-row-per-dial slot
  -- (ux_pwp_one_pending_per_param), so the live miner gets refused with
  -- 'pending_exists' by golden-harness residue rather than by evidence. That
  -- refusal is indistinguishable from a real one unless the run says so.
  SELECT count(*) INTO v_synth
    FROM public.picker_weight_proposals_v3
   WHERE status = 'pending' AND window_start >= v_epoch;
  IF v_synth > 0 THEN
    -- ⛔ plpgsql resolves `v_arr || 'literal'` to text[] and throws. Cast.
    v_warn := v_warn || 'synthetic_pending_blocks_live_minting'::text;
  END IF;

  FOREACH v_miner IN ARRAY ARRAY['mine_edit_history_v3','mine_pick_history_v3'] LOOP
    v_dry := CASE WHEN v_miner = 'mine_edit_history_v3' THEN v_edit_dry ELSE v_pick_dry END;
    v_t0  := clock_timestamp();
    -- ⛔ Only the PICK miner contends for ux_pwp_one_pending_per_param. Stamping
    --    this warning on the edit miner's row too would attach an explanation to
    --    a run it cannot explain, which is how people learn to skip warnings.
    v_row_warn := CASE WHEN v_miner = 'mine_pick_history_v3' THEN v_warn
                       ELSE '{}'::text[] END;

    -- ⛔ One miner's failure must not cost the other its run OR its log row.
    --    The subtransaction rolls back only that miner's own writes; the log
    --    INSERT below happens after the handler and survives.
    BEGIN
      IF v_miner = 'mine_edit_history_v3' THEN
        v_payload := public.mine_edit_history_v3(p_dry_run => v_edit_dry);
      ELSE
        v_payload := public.mine_pick_history_v3(p_dry_run => v_pick_dry);
      END IF;
      v_status := 'ok'; v_err := NULL; v_state := NULL;
    EXCEPTION
      -- ⛔ A statement timeout or an admin shutdown is not a miner finding. If
      --    it were swallowed here the very next INSERT would be cancelled too,
      --    and the run would die WITHOUT the log row the handler existed to
      --    write. Let those out; catch only what a miner can actually do wrong.
      WHEN query_canceled OR admin_shutdown THEN
        RAISE;
      WHEN OTHERS THEN
      v_status  := 'error';
      v_err     := SQLERRM;
      v_state   := SQLSTATE;
      v_payload := '{}'::jsonb;
    END;

    v_t1 := clock_timestamp();

    ------------------------------------------------------------ normalise ----
    -- The two miners do not share a vocabulary: the pick miner reports
    -- {ok, proposals_created, proposals_would_create} and refuses inside
    -- targets[].refused as well as in refusals[]; the edit miner reports
    -- {status, proposals_made} and refuses in skipped[].reason. Neither
    -- spelling reaches the table.
    IF v_miner = 'mine_edit_history_v3' THEN
      v_would   := COALESCE((v_payload ->> 'proposals_made')::int, 0);
      v_created := CASE WHEN v_edit_dry THEN 0 ELSE v_would END;
      v_codes   := CASE WHEN jsonb_typeof(v_payload -> 'skipped') = 'array'
                        THEN ARRAY(SELECT e ->> 'reason'
                                     FROM jsonb_array_elements(v_payload -> 'skipped') e
                                    WHERE e ->> 'reason' IS NOT NULL)
                        ELSE '{}'::text[] END;
    ELSE
      v_would   := COALESCE((v_payload ->> 'proposals_would_create')::int, 0);
      v_created := COALESCE((v_payload ->> 'proposals_created')::int, 0);
      v_codes   := CASE WHEN jsonb_typeof(v_payload -> 'refusals') = 'array'
                        THEN ARRAY(SELECT e ->> 'reason'
                                     FROM jsonb_array_elements(v_payload -> 'refusals') e
                                    WHERE e ->> 'reason' IS NOT NULL)
                        ELSE '{}'::text[] END
                || CASE WHEN jsonb_typeof(v_payload -> 'targets') = 'array'
                        THEN ARRAY(SELECT t ->> 'refused'
                                     FROM jsonb_array_elements(v_payload -> 'targets') t
                                    WHERE t ->> 'refused' IS NOT NULL)
                        ELSE '{}'::text[] END;
    END IF;

    -- ⛔ Cody, Article 4/8: stamp HERE, not at the top of the function. Both
    --    miners set app.rpc_name to their OWN name while they run, so a stamp
    --    placed before the call is overwritten and this log row would be
    --    attributed to the miner that produced it. Restored below so the
    --    provenance GUC does not leak into the rest of the transaction.
    PERFORM set_config('app.via_rpc',  'true',                  true);
    PERFORM set_config('app.rpc_name', 'run_weekly_miners_v3',  true);

    INSERT INTO public.miner_runs_v3 (
      batch_id, miner, invoked_by, dry_run, status,
      proposals_created, proposals_would_create, refusals, warnings, payload,
      error_text, error_state, started_at, finished_at, duration_ms)
    VALUES (
      v_batch, v_miner, p_invoked_by, v_dry, v_status,
      v_created, v_would,
      public.miner_refusal_tally_v3(v_codes),
      v_row_warn, v_payload,
      v_err, v_state, v_t0, v_t1,
      GREATEST(0, round(EXTRACT(EPOCH FROM (v_t1 - v_t0)) * 1000)::int))
    RETURNING run_id INTO v_run_id;

    PERFORM set_config('app.via_rpc',  'false', true);
    PERFORM set_config('app.rpc_name', '',      true);

    v_out := v_out || jsonb_build_object(
      'run_id',                 v_run_id,
      'miner',                  v_miner,
      'dry_run',                v_dry,
      'status',                 v_status,
      'proposals_created',      v_created,
      'proposals_would_create', v_would,
      'refusals',               public.miner_refusal_tally_v3(v_codes),
      'error',                  v_err,
      'duration_ms',            GREATEST(0, round(EXTRACT(EPOCH FROM (v_t1 - v_t0)) * 1000)::int));
  END LOOP;

  RETURN jsonb_build_object(
    'ok',         NOT (v_out @> '[{"status":"error"}]'::jsonb),
    'batch_id',   v_batch,
    'invoked_by', p_invoked_by,
    'pick_dry_run', v_pick_dry,
    'edit_dry_run', v_edit_dry,
    'warnings',   to_jsonb(v_warn),
    'runs',       v_out);
END
$fn$;

COMMENT ON FUNCTION public.run_weekly_miners_v3(text, boolean, boolean) IS
  'PRD-110 P4.3d. The weekly cron entry point for both P4.3 miners. Reads the dry-run dials from refill_policy_params (both default TRUE - LAW 4, shadow don''t switch), runs each miner in its own subtransaction so one failure cannot cost the other its run, normalises two different return vocabularies, and persists every invocation to miner_runs_v3. SECURITY DEFINER because it must INSERT into an append-only log that authenticated may only SELECT; search_path pinned. ⛔ A miner called directly leaves no log row - this records what the SCHEDULE found.';

-- ⛔ S-140 + Cody Article 4: name every role (the default grant is per-role and
--    explicit, so REVOKE … FROM PUBLIC removes nothing). NOT granted to
--    `authenticated`: this is a schedule entry point that can mint live
--    proposals, not an FE affordance.
REVOKE ALL ON FUNCTION public.run_weekly_miners_v3(text, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.run_weekly_miners_v3(text, boolean, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.run_weekly_miners_v3(text, boolean, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.run_weekly_miners_v3(text, boolean, boolean) TO service_role;
