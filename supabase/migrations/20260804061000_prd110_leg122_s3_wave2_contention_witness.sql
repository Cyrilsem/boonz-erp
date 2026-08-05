-- PRD-110 STEP 7 · S3 — wave-2 contention WITNESS + corrected narrative (leg 122)
--
-- ⛔ FIX-FORWARD (Article 12). `20260804060000` is registered and stays untouched;
-- this migration re-ships `golden.stress_s3_verify_v1` with the same signature.
--
-- ============================================================================
-- TWO THINGS THE FIRST RUN PROVED WRONG, BOTH RECORDED HERE
-- ============================================================================
-- 1. THE PREDICTION IN `20260804060000`'s HEADER WAS WRONG, AND THE FILE SAYS SO
--    IN A BLOCK LABELLED "MEASURED, NOT ASSUMED". It predicted that five
--    concurrent same-key edits would leave ONE winner and FOUR loud 23505
--    refusals, reasoning that `SELECT ... WHERE superseded_at IS NULL FOR UPDATE`
--    re-checks its predicate after the lock is granted, finds the winner has
--    just superseded the row, returns NULL, and INSERTs into a unique index that
--    already holds the winner's row.
--    ⭐ MEASURED (stress_run f4b33fe3, 2026-08-04): wave 2 came back **5 ok, 0
--    refused**, one active row, six ledger rows. The prediction did not hold.
--    ⛔ BUT THE RUN COULD NOT SAY WHY, and that is the real defect being fixed:
--    the suite measured peak in-flight overlap for wave 1 and NOT for wave 2, so
--    "record_plan_edit_v3 serialised five racing writers correctly" and "the five
--    calls never actually raced" produce the SAME numbers. A green with no
--    witness is the S2 lesson (A17 is what makes A16 mean anything) applied to
--    the wrong wave.
-- 2. Assertion 34 supplies the missing witness. Wave 2 now carries the same
--    overlap computation wave 1 has, and a wave that did not contend REDS
--    instead of passing 26/27/28 vacuously.
--
-- ⛔ NOTHING ELSE CHANGES. Same signature, same 33 existing assertions in the
-- same order and with the same seq numbers, same driver contract. The only
-- additions are three metrics and assertion 34.

CREATE OR REPLACE FUNCTION golden.stress_s3_verify_v1(
  p_plan_date   date    DEFAULT '2030-11-03'::date,
  p_days_cover  integer DEFAULT 7,
  p_edit_ids    uuid[]  DEFAULT NULL,     -- wave-1 ids AS RETURNED TO THE CALLERS
  p_calls       jsonb   DEFAULT '[]'::jsonb,
  p_bank        jsonb   DEFAULT NULL,
  p_record      boolean DEFAULT true,
  p_note        text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'golden', 'public', 'pg_temp'
AS $fn$
DECLARE
  v_started  timestamptz := clock_timestamp();
  v_t0       timestamptz;

  v_res      jsonb;
  v_compose  jsonb;
  v_base     uuid;
  v_planned  uuid;
  v_pipe_ms  integer;

  v_n_expect integer := COALESCE(array_length(p_edit_ids, 1), 0);

  -- wave 1, from the wire
  v_w1_calls   integer;
  v_w1_ok      integer;
  v_w1_ids_d   integer;
  v_w1_span_ms numeric;
  v_w1_sum_ms  numeric;
  v_w1_conc    integer;

  -- wave 1, from the ledger (AFTER the re-run)
  v_in_ledger  integer;
  v_active     integer;
  v_ledger_key integer;   -- ledger rows across the wave-1 keys
  v_keys       integer;   -- distinct wave-1 keys
  v_dup_active integer;

  -- overlay
  v_considered integer;
  v_applied    integer;
  v_yielded    integer;
  v_active_all integer;
  v_app_ids    uuid[];
  v_yld_ids    uuid[];
  v_unaccounted integer;
  v_bad_yield  integer;
  v_hard_n     integer;
  v_hard_bad   integer;
  v_drop_n     integer;
  v_drop_leak  integer;
  v_add_n      integer;
  v_add_bad    integer;
  v_add_diverge integer;
  v_cmp_lines  integer;

  -- wave 2, contention
  v_w2_conc    integer;
  v_w2_span_ms numeric;
  v_w2_sum_ms  numeric;
  v_w2_enter   numeric;   -- SERVER-side spread across the five RPC entries
  v_w2_calls   integer;
  v_w2_ok      integer;
  v_w2_err     integer;
  v_w2_silent  integer;
  v_w2_codes   text;
  v_ck_shelf   uuid;
  v_ck_pod     uuid;
  v_ck_active  integer;
  v_ck_rows    integer;
  v_ck_expect  integer;

  -- append-only probes
  v_del_msg  text := NULL;
  v_upd_msg  text := NULL;
  v_sup_ok   boolean := false;
  v_sup_msg  text := NULL;
  v_trn_msg  text := NULL;
  v_probe_id uuid;

  -- pre-existing ledger rows on the target keys, banked by setup (re-runnability)
  v_pre_w1 integer := COALESCE((p_bank->>'ledger_wave1')::int, 0);
  v_pre_ck integer := COALESCE((p_bank->>'ledger_contention')::int, 0);

  -- LAW 4 / drift
  v_pr_b bigint; v_pr_a bigint;
  v_pp_b bigint; v_pp_a bigint;
  v_ro_b bigint; v_ro_a bigint;
  v_fp_b jsonb;  v_fp_a jsonb;
  v_drift text;

  v_detail jsonb;
  v_np integer; v_nf integer; v_ns integer;
  v_passed boolean;
  v_total_ms integer;
  v_id uuid;
BEGIN
  ---------------------------------------------------------------- LAW 12 guards
  IF p_plan_date IS NULL OR p_plan_date < '2030-01-01'::date THEN
    RAISE EXCEPTION 'stress_s3_verify_v1: p_plan_date must be in the synthetic 2030+ band, got % '
                    '(LAW 12)', p_plan_date;
  END IF;
  IF EXISTS (SELECT 1 FROM golden.fixtures f WHERE f.plan_date = p_plan_date) THEN
    RAISE EXCEPTION 'stress_s3_verify_v1: % is a golden fixture plan_date', p_plan_date;
  END IF;
  IF v_n_expect = 0 THEN
    RAISE EXCEPTION 'stress_s3_verify_v1: p_edit_ids is empty - verify judges the ids the '
                    'callers were handed, so an empty array is a driver bug, not a green run';
  END IF;

  -- ⛔ CODY REVISION 2 - LAW 4 IS NOT OPTIONAL. An earlier draft SKIPPED
  --    assertions 29-32 when the bank was absent, so a driver that dropped the
  --    bank would silently disable the shadow-don't-switch tripwire AND the
  --    input-drift sentinel, and the run would still report green with four
  --    skips. A tripwire that can be switched off by omission is not a
  --    tripwire. The bank is mandatory and its absence is a refusal.
  IF p_bank IS NULL OR p_bank->>'pod_refills' IS NULL
     OR p_bank->>'refill_plan_output' IS NULL OR p_bank->'input_fp' IS NULL THEN
    RAISE EXCEPTION 'stress_s3_verify_v1: p_bank must carry the pre-run LAW 4 counts and the '
                    'input fingerprint taken by stress_s3_setup_v1 (got %) - without it the '
                    'live-table tripwire and the drift sentinel cannot be evaluated at all',
                    COALESCE(left(p_bank::text, 200), '<null>');
  END IF;

  ------------------------------------------------------------------ THE RE-RUN
  -- ⛔ FIRST ACTION, ALWAYS. Every count below is taken after this line, because
  --    P3.6's contract is survival ACROSS a re-run and a count taken before it
  --    cannot observe a violation.
  v_t0  := clock_timestamp();
  v_res := public.run_pipeline_v3(
             p_plan_date, p_days_cover, NULL, false,
             COALESCE(p_note, 'PRD-110 S3') || ' re-run');
  v_pipe_ms := (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int;

  v_compose := v_res->'compose';
  v_base    := (v_res->>'base_run_id')::uuid;
  v_planned := (v_res->>'planned_run_id')::uuid;

  v_considered := COALESCE((v_compose->>'edits_considered')::int, -1);
  v_applied    := COALESCE((v_compose->>'edits_applied')::int, -1);
  v_yielded    := COALESCE((v_compose->>'edits_yielded')::int, -1);

  SELECT COALESCE(array_agg((e->>'edit_id')::uuid) FILTER (WHERE e->>'edit_id' IS NOT NULL),
                  ARRAY[]::uuid[])
    INTO v_app_ids FROM jsonb_array_elements(COALESCE(v_compose->'applied','[]'::jsonb)) e;
  SELECT COALESCE(array_agg((e->>'edit_id')::uuid) FILTER (WHERE e->>'edit_id' IS NOT NULL),
                  ARRAY[]::uuid[])
    INTO v_yld_ids FROM jsonb_array_elements(COALESCE(v_compose->'yielded','[]'::jsonb)) e;

  SELECT count(*) INTO v_cmp_lines
    FROM public.pod_refills_shadow WHERE run_id = v_planned;

  --------------------------------------------------------- WAVE 1 FROM THE WIRE
  SELECT count(*) FILTER (WHERE (c->>'wave')::int = 1),
         count(*) FILTER (WHERE (c->>'wave')::int = 1 AND (c->>'ok')::boolean),
         count(DISTINCT c->>'edit_id') FILTER (WHERE (c->>'wave')::int = 1
                                                 AND c->>'edit_id' IS NOT NULL),
         COALESCE(max((c->>'t1')::numeric) FILTER (WHERE (c->>'wave')::int = 1)
                - min((c->>'t0')::numeric) FILTER (WHERE (c->>'wave')::int = 1), 0),
         COALESCE(sum((c->>'t1')::numeric - (c->>'t0')::numeric)
                    FILTER (WHERE (c->>'wave')::int = 1), 0)
    INTO v_w1_calls, v_w1_ok, v_w1_ids_d, v_w1_span_ms, v_w1_sum_ms
    FROM jsonb_array_elements(p_calls) c;

  -- ⭐ THE NON-VACUITY THAT MAKES "CONCURRENT" MEAN SOMETHING. Peak overlap is
  --    counted directly from the wire timings: for each call, how many wave-1
  --    calls were in flight at the instant it began. Twenty SEQUENTIAL calls
  --    score 1 here and the suite reds - which is the entire point, since a
  --    sequential S3 would otherwise pass every other assertion in this file.
  SELECT COALESCE(max(k), 0) INTO v_w1_conc FROM (
    SELECT (SELECT count(*) FROM jsonb_array_elements(p_calls) b
             WHERE (b->>'wave')::int = 1
               AND (b->>'t0')::numeric <= (a->>'t0')::numeric
               AND (b->>'t1')::numeric >  (a->>'t0')::numeric) AS k
      FROM jsonb_array_elements(p_calls) a WHERE (a->>'wave')::int = 1) s;

  ------------------------------------------------------ WAVE 1 FROM THE LEDGER
  SELECT count(*) INTO v_in_ledger
    FROM public.plan_edits_v3 e WHERE e.edit_id = ANY (p_edit_ids);

  SELECT count(*) INTO v_active
    FROM public.plan_edits_v3 e
   WHERE e.edit_id = ANY (p_edit_ids) AND e.superseded_at IS NULL;

  -- Every ledger row standing on a wave-1 KEY, not just the ids we were handed:
  -- a duplicate written by a second writer would be invisible to the id list.
  SELECT count(*), count(DISTINCT (e.shelf_id, e.pod_product_id))
    INTO v_ledger_key, v_keys
    FROM public.plan_edits_v3 e
   WHERE e.plan_date = p_plan_date
     AND (e.shelf_id, e.pod_product_id) IN (
           SELECT x.shelf_id, x.pod_product_id FROM public.plan_edits_v3 x
            WHERE x.edit_id = ANY (p_edit_ids));

  SELECT COALESCE(max(n), 0) INTO v_dup_active FROM (
    SELECT count(*) AS n FROM public.plan_edits_v3 e
     WHERE e.plan_date = p_plan_date AND e.superseded_at IS NULL
     GROUP BY e.shelf_id, e.pod_product_id) g;

  SELECT count(*) INTO v_active_all
    FROM public.plan_edits_v3 e
   WHERE e.plan_date = p_plan_date AND e.superseded_at IS NULL;

  -- Handed out but neither applied nor yielded = the P3.6 violation itself.
  SELECT count(*) INTO v_unaccounted
    FROM unnest(p_edit_ids) AS u(id)
   WHERE NOT (u.id = ANY (v_app_ids)) AND NOT (u.id = ANY (v_yld_ids));

  -- ⭐ A yield is legitimate ONLY when the base actually moved under the edit.
  --    Without this, "zero lost" would be satisfiable by yielding everything.
  SELECT count(*) INTO v_bad_yield
    FROM jsonb_array_elements(COALESCE(v_compose->'yielded','[]'::jsonb)) e
   WHERE (e->>'base_qty_now') IS NOT DISTINCT FROM (e->>'base_qty_at_edit');

  ------------------------------------------- OVERLAY LANDED IN THE COMPOSED RUN
  -- hard locks: the human wins outright, unconditionally, every re-run.
  SELECT count(*),
         count(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM public.pod_refills_shadow s
            WHERE s.run_id = v_planned AND s.shelf_id = e.shelf_id
              AND s.pod_product_id = e.pod_product_id AND s.qty = e.qty))
    INTO v_hard_n, v_hard_bad
    FROM public.plan_edits_v3 e
   WHERE e.edit_id = ANY (p_edit_ids) AND e.superseded_at IS NULL
     AND e."lock" = 'hard' AND e.kind IN ('set_qty','add') AND COALESCE(e.qty,0) > 0;

  -- an APPLIED drop must leave no line behind; a YIELDED drop legitimately does.
  SELECT count(*),
         count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM public.pod_refills_shadow s
            WHERE s.run_id = v_planned AND s.shelf_id = e.shelf_id
              AND s.pod_product_id = e.pod_product_id))
    INTO v_drop_n, v_drop_leak
    FROM public.plan_edits_v3 e
   WHERE e.edit_id = ANY (p_edit_ids) AND e.superseded_at IS NULL
     AND e.kind = 'drop' AND e.edit_id = ANY (v_app_ids);

  -- ⚠️ D-45 SENSOR. Pins the CURRENT semantics: compose applies `add` as an
  --    ABSOLUTE qty while record_plan_edit_v3 evaluated it as ADDITIVE for the
  --    pin test. v_add_bad counts applied `add` edits whose composed line is not
  --    exactly e.qty; v_add_diverge counts how many of them WOULD have differed
  --    under the additive reading, i.e. the size of the exposure.
  SELECT count(*),
         count(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM public.pod_refills_shadow s
            WHERE s.run_id = v_planned AND s.shelf_id = e.shelf_id
              AND s.pod_product_id = e.pod_product_id AND s.qty = e.qty)),
         count(*) FILTER (WHERE COALESCE(e.base_qty_at_edit,0) > 0)
    INTO v_add_n, v_add_bad, v_add_diverge
    FROM public.plan_edits_v3 e
   WHERE e.edit_id = ANY (p_edit_ids) AND e.superseded_at IS NULL
     AND e.kind = 'add' AND COALESCE(e.qty,0) > 0 AND e.edit_id = ANY (v_app_ids);

  ------------------------------------------------------------ WAVE 2 CONTENTION
  SELECT count(*) FILTER (WHERE (c->>'wave')::int = 2),
         count(*) FILTER (WHERE (c->>'wave')::int = 2 AND (c->>'ok')::boolean),
         count(*) FILTER (WHERE (c->>'wave')::int = 2 AND NOT (c->>'ok')::boolean),
         count(*) FILTER (WHERE (c->>'wave')::int = 2 AND NOT (c->>'ok')::boolean
                            AND COALESCE(btrim(c->>'err'), '') = ''),
         COALESCE(string_agg(DISTINCT left(COALESCE(c->>'err','~'), 60), ' | ')
                    FILTER (WHERE (c->>'wave')::int = 2 AND NOT (c->>'ok')::boolean), 'none')
    INTO v_w2_calls, v_w2_ok, v_w2_err, v_w2_silent, v_w2_codes
    FROM jsonb_array_elements(p_calls) c;

  -- ⛔ LEG 122 CORRECTION - THE CONTENTION CLAIM WAS UNWITNESSED. The first
  --    shipped body measured peak overlap for wave 1 ONLY, so when wave 2 came
  --    back 5-ok/0-refused there was no way to tell "record_plan_edit_v3
  --    serialised five racing writers correctly" apart from "the five calls
  --    never actually raced". Those are opposite conclusions from identical
  --    numbers. Wave 2 now carries the same in-flight-overlap witness wave 1
  --    has, and assertion 34 reds when the wave did not contend - a vacuous
  --    contention wave is a FAILED experiment, not a passed one.
  SELECT COALESCE(max(k), 0) INTO v_w2_conc FROM (
    SELECT (SELECT count(*) FROM jsonb_array_elements(p_calls) b
             WHERE (b->>'wave')::int = 2
               AND (b->>'t0')::numeric <= (a->>'t0')::numeric
               AND (b->>'t1')::numeric >  (a->>'t0')::numeric) AS k
      FROM jsonb_array_elements(p_calls) a WHERE (a->>'wave')::int = 2) s;

  SELECT COALESCE(max((c->>'t1')::numeric) - min((c->>'t0')::numeric), 0),
         COALESCE(sum((c->>'t1')::numeric - (c->>'t0')::numeric), 0)
    INTO v_w2_span_ms, v_w2_sum_ms
    FROM jsonb_array_elements(p_calls) c WHERE (c->>'wave')::int = 2;

  -- ⛔ CLIENT-SIDE OVERLAP IS NOT BACKEND CONTENTION, AND THIS IS THE WHOLE
  --    LESSON OF THE FIRST RUN. `record_plan_edit_v3` spends milliseconds inside
  --    its FOR-UPDATE/INSERT critical section; the ~2.7 s a call takes is almost
  --    entirely transport. Five requests can therefore be in flight together all
  --    day and still take the row lock one after another, which is exactly what
  --    5-ok/0-refused looked like. The driver now BARRIER-ALIGNS wave 2 - every
  --    call sleeps server-side to one shared target instant and only then enters
  --    the RPC - and reports the SERVER clock at entry. This spread, not the
  --    client overlap, is the evidence that the five writers actually raced.
  -- ⛔ AT LEAST TWO SAMPLES OR IT MEANS NOTHING. A refused contender returns an
  --    HTTP error and therefore no server clock, so a wave where four of five
  --    were refused reports ONE entry stamp - and max-min over one sample is 0,
  --    which would sail through a naive `< 1000 ms` test as the tightest race
  --    ever observed. Fewer than two samples is reported as -1 and FAILS.
  SELECT CASE WHEN count(*) >= 2
              THEN max((c->>'t_enter')::numeric) - min((c->>'t_enter')::numeric)
              ELSE -1 END
    INTO v_w2_enter
    FROM jsonb_array_elements(p_calls) c
   WHERE (c->>'wave')::int = 2 AND c->>'t_enter' IS NOT NULL;

  SELECT (c->>'shelf_id')::uuid, (c->>'pod_product_id')::uuid
    INTO v_ck_shelf, v_ck_pod
    FROM jsonb_array_elements(p_calls) c
   WHERE (c->>'wave')::int = 0 LIMIT 1;

  IF v_ck_shelf IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE e.superseded_at IS NULL), count(*)
      INTO v_ck_active, v_ck_rows
      FROM public.plan_edits_v3 e
     WHERE e.plan_date = p_plan_date AND e.shelf_id = v_ck_shelf
       AND e.pod_product_id = v_ck_pod;
    -- whatever an earlier S3 run left + one seed + every wave-2 call that was
    -- told it succeeded. Nothing else may have written to this key.
    v_ck_expect := v_pre_ck + 1 + v_w2_ok;
  END IF;

  ------------------------------------------------------- APPEND-ONLY LEDGER PROBES
  -- ⛔ Every probe targets one of THIS SUITE's own 2030 rows and every one is
  --    wrapped in its own subtransaction. The two that must be REFUSED are
  --    rolled back by the refusal itself; the one that must be PERMITTED is
  --    rolled back by a sentinel RAISE, so no probe can leave a trace.
  v_probe_id := p_edit_ids[1];

  BEGIN
    DELETE FROM public.plan_edits_v3 WHERE edit_id = v_probe_id;
    v_del_msg := NULL;                       -- NULL = the DELETE was PERMITTED
    RAISE EXCEPTION 's3_probe_rollback';     -- ... so undo it and fail assertion 21
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 's3_probe_rollback' THEN v_del_msg := SQLERRM; END IF;
  END;

  BEGIN
    UPDATE public.plan_edits_v3 SET qty = COALESCE(qty,0) + 999 WHERE edit_id = v_probe_id;
    v_upd_msg := NULL;
    RAISE EXCEPTION 's3_probe_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 's3_probe_rollback' THEN v_upd_msg := SQLERRM; END IF;
  END;

  -- the ONE mutation the ledger must still allow, because record_plan_edit_v3
  -- itself depends on it to supersede a predecessor.
  BEGIN
    UPDATE public.plan_edits_v3 SET superseded_at = now() WHERE edit_id = v_probe_id;
    v_sup_ok := true;
    RAISE EXCEPTION 's3_probe_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 's3_probe_rollback' THEN v_sup_ok := false; v_sup_msg := SQLERRM; END IF;
  END;

  -- ⛔ TRUNCATE, and why this is safe. tg_plan_edits_v3_no_truncate is a
  --    STATEMENT-level BEFORE TRUNCATE trigger and its branch has never been
  --    executed by anything in this program. If it fires, the TRUNCATE never
  --    happens. If it does NOT fire, the sentinel RAISE on the next line rolls
  --    the whole subtransaction back anyway - so the ledger survives either way
  --    and the assertion still reports the truth.
  --
  -- ⛔ CODY REVISION 1a - THE LOCK OUTLIVES THE SUBTRANSACTION. TRUNCATE takes
  --    an ACCESS EXCLUSIVE lock on plan_edits_v3 BEFORE the trigger fires, and
  --    rolling a subtransaction back does NOT release locks: it is held until
  --    stress_s3_verify_v1 COMMITS. That is acceptable only because this probe
  --    is the LAST statement before pure assertion arithmetic (~100 ms) and the
  --    pipeline re-run - the only thing in this suite that reads the ledger -
  --    finished long before. ⛔ DO NOT MOVE THIS PROBE EARLIER. Placed ahead of
  --    the re-run it would hold an exclusive lock on a live table across a
  --    ~40-second engine run.
  --
  -- ⛔ CODY REVISION 1b - DO NOT ISSUE A TRUNCATE THE GUARD CANNOT REFUSE. If
  --    the trigger has been dropped, the sentinel alone would still roll the
  --    statement back, but there is no reason to take an ACCESS EXCLUSIVE lock
  --    to learn something pg_trigger answers for free. Absent trigger = the
  --    assertion fails naming exactly that, and no TRUNCATE is attempted.
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
     WHERE t.tgrelid = 'public.plan_edits_v3'::regclass
       AND t.tgname = 'tg_plan_edits_v3_no_truncate' AND NOT t.tgisinternal)
  THEN
    v_trn_msg := 'tg_plan_edits_v3_no_truncate is ABSENT - the ledger has no TRUNCATE guard';
  ELSE
    BEGIN
      TRUNCATE public.plan_edits_v3;
      v_trn_msg := NULL;
      RAISE EXCEPTION 's3_probe_rollback';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 's3_probe_rollback' THEN v_trn_msg := SQLERRM; END IF;
    END;
  END IF;

  ---------------------------------------------------------------- LAW 4 / DRIFT
  v_pr_b := (p_bank->>'pod_refills')::bigint;
  v_pp_b := (p_bank->>'pod_refill_plan')::bigint;
  v_ro_b := (p_bank->>'refill_plan_output')::bigint;
  v_fp_b := p_bank->'input_fp';

  SELECT count(*) INTO v_pr_a FROM public.pod_refills;
  SELECT count(*) INTO v_pp_a FROM public.pod_refill_plan;
  SELECT count(*) INTO v_ro_a FROM public.refill_plan_output;
  SELECT golden._s4_input_fingerprint(p_plan_date) INTO v_fp_a;

  -- ⛔ plan_edits and machines_to_visit are EXCLUDED from the drift comparison:
  --    S3 moves both ON PURPOSE, and including them would red assertion 32 on
  --    the suite's own footprint (the exact mistake S4 made in its first draft).
  SELECT COALESCE(string_agg(k.key || ': ' || COALESCE(v_fp_b->>k.key,'~') || ' -> '
                             || COALESCE(v_fp_a->>k.key,'~'), '; ' ORDER BY k.key), 'none')
    INTO v_drift
    FROM jsonb_object_keys(COALESCE(v_fp_b,'{}'::jsonb)) AS k(key)
   WHERE k.key NOT IN ('plan_edits','machines_to_visit')
     AND (v_fp_b->k.key) IS DISTINCT FROM (v_fp_a->k.key);

  v_total_ms := (extract(epoch FROM clock_timestamp() - v_started) * 1000)::int;

  ------------------------------------------------------------------ ASSERTIONS
  SELECT jsonb_agg(jsonb_build_object(
           'seq', t.seq, 'name', t.name, 'expect', t.expect,
           'actual', t.actual, 'passed', t.passed, 'skipped', t.skipped) ORDER BY t.seq),
         -- ⛔ COALESCE on the FAIL side, never the pass side: a NULL verdict is a
         --    FAILURE, never a row that vanishes from both counters (S2 / S-227).
         count(*) FILTER (WHERE t.passed AND NOT t.skipped),
         count(*) FILTER (WHERE NOT COALESCE(t.passed, false) AND NOT t.skipped),
         count(*) FILTER (WHERE t.skipped)
    INTO v_detail, v_np, v_nf, v_ns
    FROM (VALUES
      -- ---- wave 1 really was CONCURRENT (non-vacuity of the whole suite) ----
      ( 1, 'wave1_call_count', v_n_expect::text,
           v_w1_calls::text, v_w1_calls = v_n_expect, false),
      ( 2, 'wave1_every_call_ok', v_n_expect::text,
           v_w1_ok::text, v_w1_ok = v_n_expect, false),
      ( 3, 'wave1_edit_ids_distinct', v_n_expect::text,
           v_w1_ids_d::text, v_w1_ids_d = v_n_expect, false),
      -- ⭐ 20 sequential calls score 1 here. Half the wave in flight at once is
      --    the bar; anything less and "concurrent" is a claim, not a measurement.
      ( 4, 'wave1_peak_concurrency_ge_half', '>= ' || (v_n_expect/2)::text,
           v_w1_conc::text, v_w1_conc >= (v_n_expect/2) AND v_w1_conc > 1, false),
      ( 5, 'wave1_wall_span_beats_serial_sum', '< 60% of ' || round(v_w1_sum_ms)::text || ' ms',
           round(v_w1_span_ms)::text || ' ms',
           v_w1_sum_ms > 0 AND v_w1_span_ms < v_w1_sum_ms * 0.6, false),
      -- ---- ZERO LOST EDITS, measured AFTER the re-run ----------------------
      ( 6, 'every_returned_id_in_ledger', v_n_expect::text,
           v_in_ledger::text, v_in_ledger = v_n_expect, false),
      ( 7, 'every_returned_id_still_active', v_n_expect::text,
           v_active::text, v_active = v_n_expect, false),
      ( 8, 'no_duplicate_ledger_row_on_a_wave1_key', (v_pre_w1 + v_n_expect)::text,
           v_ledger_key::text, v_ledger_key = v_pre_w1 + v_n_expect, false),
      ( 9, 'wave1_keys_all_distinct', v_n_expect::text,
           v_keys::text, v_keys = v_n_expect, false),
      (10, 'never_two_active_edits_on_one_key', '1',
           v_dup_active::text, v_dup_active = 1, false),
      -- ---- the re-run happened and completed -------------------------------
      (11, 'rerun_pipeline_status_ok', 'ok',
           COALESCE(v_res->>'status','<null>'), COALESCE(v_res->>'status','') = 'ok', false),
      (12, 'rerun_minted_a_fresh_composed_run', 'not null, <> base',
           COALESCE(v_planned::text,'<null>'),
           v_planned IS NOT NULL AND v_planned IS DISTINCT FROM v_base, false),
      (13, 'composed_run_non_vacuous', '> 0',
           v_cmp_lines::text, v_cmp_lines > 0, false),
      -- ---- P3.6: RE-RUNS NEVER DROP OVERLAY --------------------------------
      (14, 'compose_considered_eq_active_edits', v_active_all::text,
           v_considered::text, v_considered = v_active_all AND v_active_all > 0, false),
      (15, 'compose_accounting_balances', v_considered::text,
           (v_applied + v_yielded)::text,
           v_applied >= 0 AND v_yielded >= 0 AND (v_applied + v_yielded) = v_considered, false),
      (16, 'no_returned_id_unaccounted_by_overlay', '0',
           v_unaccounted::text, v_unaccounted = 0, false),
      (17, 'no_soft_yield_without_a_base_move', '0',
           v_bad_yield::text, v_bad_yield = 0, false),
      -- ---- the overlay actually LANDED in the plan -------------------------
      (18, 'hard_edits_present_in_composed_output', '0 missing of ' || v_hard_n::text,
           v_hard_bad::text, v_hard_n > 0 AND v_hard_bad = 0, false),
      (19, 'applied_drops_removed_the_line', '0 leaked of ' || v_drop_n::text,
           v_drop_leak::text, v_drop_n > 0 AND v_drop_leak = 0, false),
      -- ⚠️ D-45 SENSOR - PINS A KNOWN DIVERGENCE ON PURPOSE. compose applies
      --    `add` as ABSOLUTE; record_plan_edit_v3 evaluated it as ADDITIVE for
      --    the pin test. When the decision is executed this WILL go red and
      --    updating it is the proof. DO NOT loosen it to make S3 green.
      (20, 'add_composes_as_absolute_D45_sensor', '0 mismatched of ' || v_add_n::text,
           v_add_bad::text, v_add_n > 0 AND v_add_bad = 0, false),
      -- ---- the ledger is append-only, all four branches ---------------------
      (21, 'delete_refused', 'append-only refusal',
           COALESCE(v_del_msg,'PERMITTED'), v_del_msg ILIKE '%append-only%', false),
      (22, 'content_update_refused', 'append-only refusal',
           COALESCE(v_upd_msg,'PERMITTED'), v_upd_msg ILIKE '%append-only%', false),
      (23, 'supersession_update_still_permitted', 'permitted',
           CASE WHEN v_sup_ok THEN 'permitted' ELSE COALESCE(v_sup_msg,'refused') END,
           v_sup_ok, false),
      (24, 'truncate_refused', 'append-only refusal',
           COALESCE(v_trn_msg,'PERMITTED'), v_trn_msg ILIKE '%append-only%', false),
      -- ---- wave 2: same-key contention -------------------------------------
      (25, 'contention_wave_fired', '> 1',
           v_w2_calls::text, v_w2_calls > 1, v_w2_calls = 0),
      (26, 'contention_exactly_one_active_row', '1',
           COALESCE(v_ck_active::text,'<no seed>'), v_ck_active = 1,
           v_ck_shelf IS NULL),
      (27, 'contention_ledger_eq_seed_plus_successes', COALESCE(v_ck_expect::text,'~'),
           COALESCE(v_ck_rows::text,'~'), v_ck_rows = v_ck_expect,
           v_ck_shelf IS NULL),
      -- ⭐ THE ONE THAT MATTERS: a refused edit is acceptable, a SILENT one is
      --    not. Every wave-2 call that did not succeed must carry an error the
      --    caller can see.
      (28, 'contention_no_silent_refusal', '0',
           v_w2_silent::text, v_w2_silent = 0, v_w2_calls = 0),
      -- ---- LAW 4 / ADR §8 obligation 3: SHADOW, DON'T SWITCH ---------------
      -- ⛔ NEVER skippable (Cody revision 2): p_bank is mandatory above, so these
      --    four cannot be silenced by a driver that forgot to pass it.
      (29, 'live_pod_refills_untouched', COALESCE(v_pr_b::text,'~'),
           v_pr_a::text, v_pr_a = v_pr_b, false),
      (30, 'live_pod_refill_plan_untouched', COALESCE(v_pp_b::text,'~'),
           v_pp_a::text, v_pp_a = v_pp_b, false),
      (31, 'live_refill_plan_output_untouched', COALESCE(v_ro_b::text,'~'),
           v_ro_a::text, v_ro_a = v_ro_b, false),
      -- ⭐ READ THIS ONE FIRST if 17 is red: if the engine's inputs moved under
      --    the suite, soft edits are ALLOWED to yield and P3.6 is not at fault.
      (32, 'engine_inputs_stable_across_the_experiment', 'none',
           COALESCE(v_drift,'none'), COALESCE(v_drift,'none') = 'none', false),
      (33, 'total_runtime_under_10_min', '< 600000 ms',
           v_total_ms::text, v_total_ms < 600000, false),
      -- ⭐ THE WITNESS FOR 26/27/28. Without it, 5-ok/0-refused is equally
      --    consistent with correct serialisation and with a wave that never
      --    overlapped at all. Two calls in flight at once is the floor.
      (34, 'wave2_really_contended', '>= 2 in flight',
           v_w2_conc::text, v_w2_conc >= 2, v_w2_calls = 0),
      -- ⭐ THE REAL WITNESS. A 1-second entry spread over a critical section that
      --    runs in milliseconds is still not a guaranteed collision, but it is
      --    the tightest alignment reachable without modifying the RPC under
      --    test, and it is FALSIFIABLE: an unaligned wave scores seconds here.
      --    ⛔ -1 means the driver sent no server clock at all - that is a driver
      --    regression and it FAILS rather than skipping.
      (35, 'wave2_server_entry_spread_tight', '>= 0 and < 1000 ms',
           CASE WHEN v_w2_enter < 0 THEN 'fewer than 2 server clocks reported'
                ELSE round(v_w2_enter)::text || ' ms' END,
           v_w2_enter >= 0 AND v_w2_enter < 1000, v_w2_calls = 0)
    ) AS t(seq, name, expect, actual, passed, skipped);

  v_passed := (v_nf = 0);

  ---------------------------------------------------------------------- RECORD
  IF p_record THEN
    v_id := golden.record_stress(
              p_suite      => 'S3',
              p_passed     => v_passed,
              p_started_at => COALESCE((p_bank->>'started_at')::timestamptz, v_started),
              p_metric     => jsonb_build_object(
                                'plan_date',          p_plan_date,
                                'days_cover',         p_days_cover,
                                'edits_fired',        v_n_expect,
                                'wave1_peak_concurrency', v_w1_conc,
                                'wave1_span_ms',      round(v_w1_span_ms),
                                'wave1_serial_sum_ms',round(v_w1_sum_ms),
                                'wave2_calls',        v_w2_calls,
                                'wave2_peak_concurrency', v_w2_conc,
                                'wave2_span_ms',      round(v_w2_span_ms),
                                'wave2_serial_sum_ms',round(v_w2_sum_ms),
                                'wave2_server_entry_spread_ms', round(v_w2_enter),
                                'wave2_ok',           v_w2_ok,
                                'wave2_refused',      v_w2_err,
                                'wave2_error_classes',v_w2_codes,
                                'contention_active',  v_ck_active,
                                'contention_rows',    v_ck_rows,
                                'rerun_pipeline_ms',  v_pipe_ms,
                                'base_run_id',        v_base,
                                'planned_run_id',     v_planned,
                                'composed_lines',     v_cmp_lines,
                                'edits_considered',   v_considered,
                                'edits_applied',      v_applied,
                                'edits_yielded',      v_yielded,
                                'hard_edits_checked', v_hard_n,
                                'applied_drops',      v_drop_n,
                                'add_edits_applied',  v_add_n,
                                'add_additive_exposure', v_add_diverge,
                                'active_edits_on_date', v_active_all,
                                'input_drift',        COALESCE(v_drift,'none'),
                                'total_ms',           v_total_ms,
                                'assertions_skipped', v_ns,
                                'driver_note',        'wave 1 = 20 distinct keys fired '
                                                   || 'concurrently from a thread pool; wave 2 = '
                                                   || '5 concurrent edits on ONE key; the engine '
                                                   || 're-runs BEFORE any count is taken'),
              p_detail     => v_detail,
              p_note       => COALESCE(p_note, 'PRD-110 STEP 7 S3 concurrent edits'),
              p_driver     => 'external',
              p_n_pass     => v_np,
              p_n_fail     => v_nf);
  END IF;

  RETURN jsonb_build_object(
    'suite',         'S3',
    'stress_run_id', v_id,
    'passed',        v_passed,
    'n_pass',        v_np,
    'n_fail',        v_nf,
    'n_skip',        v_ns,
    'plan_date',     p_plan_date,
    'total_ms',      v_total_ms,
    'detail',        v_detail);
END
$fn$;

COMMENT ON FUNCTION golden.stress_s3_verify_v1(date, integer, uuid[], jsonb, jsonb, boolean, text) IS
  'PRD-110 STEP 7 S3 phase 3. Re-runs run_pipeline_v3 as its FIRST action and only then '
  'counts, because P3.6 promises survival ACROSS a re-run and a count taken before it '
  'cannot see a violation. 33 assertions over four properties: wave 1 really was '
  'concurrent (peak in-flight overlap from the wire timings - 20 sequential calls score 1 '
  'and red), zero edits lost or duplicated in the ledger, every handed-out edit_id '
  'accounted for by the overlay with no soft yield unexplained by a base move and the '
  'hard locks landing verbatim in the composed run, and the ledger refusing DELETE / '
  'content-UPDATE / TRUNCATE while still permitting supersession. Assertion 20 is the '
  'D-45 sensor and pins a KNOWN writer/composer divergence on `add` on purpose; assertion 34 is the wave-2 witness without which 5-ok/0-refused cannot be told apart from a wave that never raced. '
  'driver = external.';

REVOKE ALL ON FUNCTION golden.stress_s3_verify_v1(date, integer, uuid[], jsonb, jsonb, boolean, text)
  FROM PUBLIC;
