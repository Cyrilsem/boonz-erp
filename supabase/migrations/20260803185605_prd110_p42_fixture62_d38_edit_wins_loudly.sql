-- PRD-110 P3.6/P4.2 / CS DECISION D-38 — FIXTURE FIRST (LAW 1). No verb edit in this migration.
--
-- CS answered D-38 → EDIT WINS, LOUDLY. Below-pin edits apply; the override is recorded on the
-- line AND written to the feedback ledger as pin-contradiction evidence feeding G12.
-- This migration writes the proof that reddens on today's bodies and greens on the wired ones.
--
-- ⭐ PREMISE RE-DERIVED LIVE BEFORE A LINE WAS WRITTEN (S-158). All of D-38's wording holds:
--      · record_plan_edit_v3 does NOT mention planning_pins_v3 or the pins view at all —
--        the edit silently wins exactly as S-130 recorded. Verified on prosrc, not assumed.
--      · plan_edits_v3 carries NO column that could record an override.
--      · feedback_ledger_v3's intent CHECK is a CLOSED list of eight; none of them means
--        "a human overrode a pin".
--    Smoke-probed live (S-149): the whole scenario runs, the edit lands at qty 2 against an
--    active min_facing floor of 6, and NOTHING anywhere records the contradiction.
--
-- ⛔ WHY THE FLOOR IS READ FROM THE ENGINE'S OWN LINE, NOT RECOMPUTED. engine_add_pod_v3
--    already writes pin_floor_units / pin_count / pin_binds / need_raw_no_pin onto EVERY
--    shadow line (LAW 5 — an unpinned line records 0/0/false explicitly). record_plan_edit_v3
--    already resolves that exact base row to compute base_qty_at_edit. Re-deriving the floor
--    from v_planning_pins_active_v3 inside the edit path would create a SECOND copy of the
--    pin ladder — the Article 16 sin D-35 just retired, and the S-165 guard-set trap.
--    ⭐ The edit path must ASK the engine what floor it applied, never recompute it.
--
-- ⛔ THE FLOOR, NOT pin_binds, IS THE TEST. pin_binds means "the pin is what decided need_raw".
--    A pin of 6 on a line the ladder already took to 8 does not bind — yet an edit down to 3
--    is still an override of a live floor. Testing pin_binds would silently miss that whole
--    class. Seq 9 pins the distinction with a non-binding floor.
--
-- ⭐ ZERO RESIDUE BY CONSTRUCTION (S-153). Everything is planted inside ONE plpgsql
--    subtransaction which then RAISEs to unwind: rows roll back, plpgsql variables survive,
--    and the scratch write happens after. This matters more here than usual — the scenario
--    plants a planning_pins_v3 row, and a leaked pin is live refill policy on a real machine.
--    Seq 15/16 re-prove the unwind on every run rather than trusting it once.
--
-- ⭐ THE SPREAD IS THE POINT (S-157/S-162). "Contradiction recorded" is trivially fakeable by
--    a verb that flags everything. The scenario therefore drives THREE edits on three shelves
--    of one machine: below a live floor (must flag), above a live floor (must NOT flag), and a
--    cut to zero on an unpinned shelf whose engine line recorded floor 0 (must NOT flag, and
--    must record 0 explicitly rather than NULL). Seq 8/9/10 carry that spread.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, notes, scenario_sql)
VALUES (
  62,
  'Edit wins, loudly (D-38): a human edit below a live pin floor still applies, but it can no longer apply in silence — the override is stamped on the edit line and lands in the feedback ledger as pin-contradiction evidence',
  'PRD-110 D-38 (raised leg 82, answered 2026-08-01): P3.6 says re-runs never drop the edit overlay; P4.2 says an approved pin is a constraint the plan respects. When an edit goes below a pin floor exactly one rule must yield, and nothing decided which — so the edit won SILENTLY (S-130), leaving a CS-approved pin eroding with no trace anyone could review.',
  'P4',
  DATE '2030-06-17',
  'Cast probed live: machine 0a9a4836 with three shelves sharing one Active pod<->boonz mapping. Window 2030-06-15..21 probed virgin on pod_refills_shadow / plan_edits_v3 / machines_to_visit / refill_plan_output before adoption; the fixture re-verifies every run. All writes unwind via S-153 subtransaction RAISE.',
$fx62$
DO $do$
DECLARE
  v_mach    uuid := '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04';
  v_sh_lo   uuid := 'bb99e47a-0954-4ca4-9239-51ca7d2c1e8e';  -- edited BELOW a live floor
  v_sh_hi   uuid := '48d19499-5d25-495f-8ffc-78842b5d30e2';  -- edited ABOVE a live floor
  v_sh_np   uuid := '558ad2f1-57b3-4026-b3d3-6e423bf2d34f';  -- unpinned, engine floor 0
  v_pod     uuid := '1eaa0773-ddda-411a-9ba6-3d2d3e3c6584';
  v_bp      uuid := 'dc368bf2-3da1-442e-82af-f2bb30cc9c96';
  v_pd      date := DATE '2030-06-17';
  v_run     uuid := gen_random_uuid();
  v_virgin  boolean;
  v_cols    int;
  v_intent_ok boolean;
  v_trg_ok  boolean;
  v_e_lo    jsonb; v_e_hi jsonb; v_e_np jsonb;
  v_id_lo   uuid;  v_id_hi uuid; v_id_np uuid;
  v_f_lo    text := 'no_column'; v_f_hi text := 'no_column'; v_f_np text := 'no_column';
  v_fl_lo   text := 'no_column'; v_fl_np text := 'no_column';
  v_fb_lo   int  := -1;
  v_fb_link text := 'no_column';
  v_qty_lo  int;
  v_applied text;
  v_resid   int;
  v_ledger_before int; v_ledger_after int; v_ledger_final int;
  v_edits_before  int; v_edits_after  int; v_edits_final  int;
  v_pins_after    int;
  v_src     text;
BEGIN
  DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

  -- (1) STRUCTURAL — measured on the LIVE catalogue, outside the subtransaction, so these
  --     read the same before and after the unwind.
  SELECT count(*) INTO v_cols
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='plan_edits_v3'
     AND column_name IN ('pin_floor_at_edit','pin_contradiction','pin_feedback_id');

  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid='public.feedback_ledger_v3'::regclass
       AND conname='feedback_ledger_v3_intent_check'
       AND pg_get_constraintdef(oid) LIKE '%pin_contradiction%') INTO v_intent_ok;

  -- ⛔ The append-only trigger enumerates its immutable columns as an EXPLICIT tuple. A new
  --    column it does not name is silently mutable after insert — which would make the
  --    D-38 evidence quietly erasable and turn "loudly" back into "silently".
  SELECT p.prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='tg_plan_edits_v3_append_only';
  v_trg_ok := v_src LIKE '%pin_contradiction%' AND v_src LIKE '%pin_floor_at_edit%'
              AND v_src LIKE '%pin_feedback_id%';

  v_virgin := NOT (
       EXISTS (SELECT 1 FROM public.pod_refills_shadow WHERE plan_date BETWEEN DATE '2030-06-15' AND DATE '2030-06-21')
    OR EXISTS (SELECT 1 FROM public.plan_edits_v3     WHERE plan_date BETWEEN DATE '2030-06-15' AND DATE '2030-06-21')
    OR EXISTS (SELECT 1 FROM public.machines_to_visit WHERE plan_date BETWEEN DATE '2030-06-15' AND DATE '2030-06-21')
    OR EXISTS (SELECT 1 FROM public.refill_plan_output WHERE plan_date BETWEEN DATE '2030-06-15' AND DATE '2030-06-21'));

  SELECT count(*) INTO v_ledger_before FROM public.feedback_ledger_v3;
  SELECT count(*) INTO v_edits_before  FROM public.plan_edits_v3;

  IF v_virgin THEN
    BEGIN
      PERFORM set_config('request.jwt.claims',
        '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

      -- ---- the engine's own lines, carrying the floors it applied (LAW 5 shape) ----
      INSERT INTO public.pod_refills_shadow
        (run_id, engine_tag, produced_at, plan_date, machine_id, shelf_id, pod_product_id,
         qty, current_stock, max_stock, days_cover, signal, wh_available_pod, clamp_reason,
         reasoning, velocity_instock, availability_basis)
      VALUES
        -- floor 6 and it BINDS: the ladder wanted 2, the pin took it to 6
        (v_run,'engine_add_pod_v3', now(), v_pd, v_mach, v_sh_lo, v_pod, 6, 0, 10, 7, 'fx62', 50, NULL,
         jsonb_build_object('pin_floor_units',6,'pin_count',1,'pin_binds',true,'need_raw_no_pin',2), 1.5,'boonz_wh'),
        -- floor 6 that does NOT bind: the ladder already wanted 9 on its own
        (v_run,'engine_add_pod_v3', now(), v_pd, v_mach, v_sh_hi, v_pod, 9, 0, 12, 7, 'fx62', 50, NULL,
         jsonb_build_object('pin_floor_units',6,'pin_count',1,'pin_binds',false,'need_raw_no_pin',9), 1.5,'boonz_wh'),
        -- unpinned: the engine looked and recorded ZERO explicitly
        (v_run,'engine_add_pod_v3', now(), v_pd, v_mach, v_sh_np, v_pod, 3, 0, 10, 7, 'fx62', 50, NULL,
         jsonb_build_object('pin_floor_units',0,'pin_count',0,'pin_binds',false,'need_raw_no_pin',3), 1.5,'boonz_wh');

      -- ---- the CS-approved pins the edits are about to argue with ----
      INSERT INTO public.planning_pins_v3
        (machine_id, shelf_id, boonz_product_id, kind, value, mode, source, feedback_ids)
      VALUES (v_mach, v_sh_lo, v_bp, 'min_facing', 6, 'perpetual', 'cs_direct', '{}'),
             (v_mach, v_sh_hi, v_bp, 'min_facing', 6, 'perpetual', 'cs_direct', '{}');

      -- ---- the three edits ----
      v_e_lo := public.record_plan_edit_v3(v_pd, v_sh_lo, v_pod, 'set_qty', 2, 'soft',
                  'driver reports this shelf overflows at six units on every visit');
      v_e_hi := public.record_plan_edit_v3(v_pd, v_sh_hi, v_pod, 'set_qty', 8, 'soft',
                  'trimming to eight units, still comfortably above the agreed floor');
      v_e_np := public.record_plan_edit_v3(v_pd, v_sh_np, v_pod, 'set_qty', 0, 'soft',
                  'skipping this shelf entirely this visit, nothing is pinned here');

      v_id_lo := (v_e_lo->>'edit_id')::uuid;
      v_id_hi := (v_e_hi->>'edit_id')::uuid;
      v_id_np := (v_e_np->>'edit_id')::uuid;

      -- the edit APPLIED is the half of D-38 that must not regress
      SELECT qty INTO v_qty_lo FROM public.plan_edits_v3 WHERE edit_id = v_id_lo;
      v_applied := CASE WHEN v_qty_lo = 2 AND (v_e_lo->>'base_qty_at_edit') = '6'
                        THEN 'applied_at_2_over_base_6' ELSE 'unexpected' END;

      -- ---- the D-38 payload, read only if the columns exist ----
      IF v_cols = 3 THEN
        EXECUTE 'SELECT COALESCE(pin_contradiction::text,''<null>''), COALESCE(pin_floor_at_edit::text,''<null>'')
                   FROM public.plan_edits_v3 WHERE edit_id=$1'
          INTO v_f_lo, v_fl_lo USING v_id_lo;
        EXECUTE 'SELECT COALESCE(pin_contradiction::text,''<null>'') FROM public.plan_edits_v3 WHERE edit_id=$1'
          INTO v_f_hi USING v_id_hi;
        EXECUTE 'SELECT COALESCE(pin_contradiction::text,''<null>''), COALESCE(pin_floor_at_edit::text,''<null>'')
                   FROM public.plan_edits_v3 WHERE edit_id=$1'
          INTO v_f_np, v_fl_np USING v_id_np;
        EXECUTE 'SELECT CASE WHEN EXISTS (SELECT 1 FROM public.plan_edits_v3 e
                               JOIN public.feedback_ledger_v3 f ON f.feedback_id = e.pin_feedback_id
                              WHERE e.edit_id=$1 AND f.intent=''pin_contradiction''
                                AND f.machine_id=$2 AND f.shelf_id=$3)
                          THEN ''linked'' ELSE ''not_linked'' END'
          INTO v_fb_link USING v_id_lo, v_mach, v_sh_lo;
      END IF;

      SELECT count(*) INTO v_fb_lo
        FROM public.feedback_ledger_v3
       WHERE machine_id = v_mach AND intent = 'pin_contradiction';

      SELECT count(*) INTO v_ledger_after FROM public.feedback_ledger_v3;
      SELECT count(*) INTO v_edits_after  FROM public.plan_edits_v3;

      RAISE EXCEPTION 'FX62_UNWIND';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'FX62_UNWIND' THEN
        v_applied := 'scenario_error: ' || SQLERRM;
      END IF;
    END;
  END IF;

  -- (2) RESIDUE — the unwind must have left the fleet exactly as it was found.
  SELECT (SELECT count(*) FROM public.pod_refills_shadow WHERE plan_date = v_pd)
       + (SELECT count(*) FROM public.plan_edits_v3      WHERE plan_date = v_pd)
    INTO v_resid;
  SELECT count(*) INTO v_pins_after
    FROM public.planning_pins_v3 WHERE machine_id = v_mach AND source = 'cs_direct';
  -- ⭐ Residue is measured as a SAME-RUN DELTA, never as an absolute count. D-38 exists to
  --    make pin_contradiction rows ACCUMULATE in production; an absolute "= 0" assertion
  --    would go permanently red the first time the feature did its job.
  SELECT count(*) INTO v_ledger_final FROM public.feedback_ledger_v3;
  SELECT count(*) INTO v_edits_final  FROM public.plan_edits_v3;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'd38_edit_vs_pin', jsonb_build_object(
    'window_virgin',      CASE WHEN v_virgin THEN 'yes' ELSE 'no' END,
    'new_columns',        v_cols,
    'intent_vocab_ok',    CASE WHEN v_intent_ok THEN 'yes' ELSE 'no' END,
    'trigger_protects',   CASE WHEN v_trg_ok THEN 'yes' ELSE 'no' END,
    'edit_applied',       COALESCE(v_applied,'<null>'),
    'flag_below_floor',   v_f_lo,
    'flag_above_floor',   v_f_hi,
    'flag_unpinned',      v_f_np,
    'floor_below',        v_fl_lo,
    'floor_unpinned',     v_fl_np,
    'ledger_evidence',    v_fb_lo,
    'ledger_link',        v_fb_link,
    'residue_rows',       v_resid,
    'pins_leaked',        v_pins_after,
    'ledger_written',     COALESCE(v_ledger_after, v_ledger_before) - v_ledger_before,
    'ledger_residue',     v_ledger_final - v_ledger_before,
    'edits_residue',      v_edits_final  - v_edits_before));
END $do$;
$fx62$
)
ON CONFLICT (fixture_id) DO UPDATE
  SET name            = EXCLUDED.name,
      source_incident = EXCLUDED.source_incident,
      phase_required  = EXCLUDED.phase_required,
      plan_date       = EXCLUDED.plan_date,
      notes           = EXCLUDED.notes,
      scenario_sql    = EXCLUDED.scenario_sql;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
VALUES
 (62, 1,
  'D-38 safety: the 2030-06-15..21 window is still virgin on all four tables, so the scenario can plant an engine run and three edits without colliding with anything. A red here means pick a new window, never widen the fixture',
  $q$SELECT COALESCE((SELECT value->>'window_virgin' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'yes', 'P4'),

 (62, 2,
  'D-38 premise: the scenario actually ran to completion. Any plant, verb call or read that threw lands its message here, so a broken scenario reports itself instead of quietly leaving every flag at its no_column default and reading like a clean red',
  $q$SELECT COALESCE((SELECT value->>'edit_applied' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'applied_at_2_over_base_6', 'P4'),

 (62, 3,
  'D-38 CORE (a): plan_edits_v3 can RECORD an override at all - pin_floor_at_edit, pin_contradiction and pin_feedback_id all exist. CS asked for the override to be recorded ON THE LINE and today the table has nowhere to put it (RED until the wiring lands)',
  $q$SELECT COALESCE((SELECT value->>'new_columns' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '3', 'P4'),

 (62, 4,
  'D-38 CORE (b): the ledger has a word for this. feedback_ledger_v3 intent accepts pin_contradiction, so the evidence is IDENTIFIABLE by G12 instead of buried in the other bucket. Mapping it onto a nearest-looking existing intent is the exact error class D-40 names (RED until the vocabulary lands)',
  $q$SELECT COALESCE((SELECT value->>'intent_vocab_ok' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'yes', 'P4'),

 (62, 5,
  'D-38 CORE (c): the append-only trigger names the three new columns in its immutable tuple. It enumerates protected columns EXPLICITLY, so a column it does not name stays silently UPDATE-able - the pin-contradiction record could be erased after the fact and loudly would decay back to silently (RED until the trigger is extended)',
  $q$SELECT COALESCE((SELECT value->>'trigger_protects' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'yes', 'P4'),

 (62, 6,
  'D-38 CORE (d): an edit that lands 2 units under a live min_facing floor of 6 is FLAGGED on its own line. This is the whole decision - the override stops being invisible (RED until the wiring lands)',
  $q$SELECT COALESCE((SELECT value->>'flag_below_floor' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'true', 'P4'),

 (62, 7,
  'D-38 CORE (e): the flagged line also carries the floor it argued with, read from the engine line the human was reacting to rather than recomputed from the pins view. Recomputing would be a second copy of the pin ladder - the Article 16 sin D-35 just retired',
  $q$SELECT COALESCE((SELECT value->>'floor_below' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '6', 'P4'),

 (62, 8,
  'D-38 spread (S-157): an edit ABOVE the same live floor is NOT flagged. Without this a verb that flags every edit would satisfy seq 6 perfectly and the flag would mean nothing',
  $q$SELECT COALESCE((SELECT value->>'flag_above_floor' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'false', 'P4'),

 (62, 9,
  'D-38 spread: a cut to ZERO on an unpinned shelf is NOT flagged. The trigger for the flag is the pin floor, never the size of the cut - seq 6 and seq 9 are both large downward edits and only one of them is an override',
  $q$SELECT COALESCE((SELECT value->>'flag_unpinned' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'false', 'P4'),

 (62, 10,
  'D-38 explicitness (LAW 5): the unpinned line records floor 0, not NULL. The engine writes 0/0/false explicitly so that no pin applied is never indistinguishable from nobody looked, and the edit path must inherit that discipline rather than reintroduce the ambiguity',
  $q$SELECT COALESCE((SELECT value->>'floor_unpinned' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '0', 'P4'),

 (62, 11,
  'D-38 CORE (f): exactly ONE pin_contradiction row reached the feedback ledger for this machine - the below-floor edit produced evidence and the other two edits did not. This is the half of CS answer (b) that feeds G12',
  $q$SELECT COALESCE((SELECT value->>'ledger_evidence' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '1', 'P4'),

 (62, 12,
  'D-38 CORE (g): the edit line and its ledger row are LINKED, and the ledger row carries the same machine and shelf. Evidence nobody can trace back to the edit that produced it is evidence nobody can review, which is the failure D-38 was raised about',
  $q$SELECT COALESCE((SELECT value->>'ledger_link' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', 'linked', 'P4'),

 (62, 13,
  'D-38 anti-regression (P3.6): the edit still WINS. CS chose (b) edit wins loudly, not (a) pin wins - the recorded qty is 2 against a base of 6, so nothing here clamped the human standing at the machine',
  $q$SELECT COALESCE((SELECT value->>'edit_applied' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'contains', 'applied_at_2', 'P4'),

 (62, 14,
  'D-38 residue (S-153): the subtransaction unwound - zero pod_refills_shadow and zero plan_edits_v3 rows survive on the fixture plan_date. plan_edits_v3 is append-only, so a fixture that did NOT unwind would mint permanent rows on every single run',
  $q$SELECT COALESCE((SELECT value->>'residue_rows' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '0', 'P4'),

 (62, 15,
  'D-38 residue: ZERO planning_pins_v3 rows leaked onto the cast machine. A leaked pin is not fixture noise - it is live refill policy on a real machine that would silently raise its floors forever',
  $q$SELECT COALESCE((SELECT value->>'pins_leaked' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '0', 'P4'),

 (62, 16,
  'D-38 residue: the feedback ledger is back to its pre-run size, measured as a same-run delta. The scenario deliberately makes the verb write a ledger row, so this is what stops fixture 62 from inflating the very G12 evidence stream it exists to prove. ⛔ Measured as a delta and never as an absolute count, because D-38 succeeding means production pin_contradiction rows accumulate',
  $q$SELECT COALESCE((SELECT value->>'ledger_residue' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '0', 'P4'),

 (62, 17,
  'D-38 anti-vacuity (S-162): the ledger row was genuinely WRITTEN inside the scenario before the unwind erased it. Without this, seq 16 is satisfied just as well by a verb that never wrote anything at all, and seq 11/12 would be the only thing standing between a real emit and a no-op',
  $q$SELECT COALESCE((SELECT value->>'ledger_written' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '1', 'P4'),

 (62, 18,
  'D-38 residue: plan_edits_v3 is back to its pre-run size as a same-run delta. The table is append-only with no DELETE path, so a fixture that failed to unwind could never clean up after itself - it would mint three permanent edit rows on every run forever',
  $q$SELECT COALESCE((SELECT value->>'edits_residue' FROM golden.scratch WHERE fixture_id=62 AND key='d38_edit_vs_pin'),'absent')$q$,
  'eq', '0', 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description    = EXCLUDED.description,
      check_sql      = EXCLUDED.check_sql,
      expect_op      = EXCLUDED.expect_op,
      expect         = EXCLUDED.expect,
      phase_required = EXCLUDED.phase_required;
