-- PRD-110 · D-27(a) · leg 150
-- THE DE-DUPLICATION. One canonical definition of an m2m donor surplus.
--
-- Proven RED first by fixture 71 (20260808120000): 16/31, n_fail 15, zero scenario_error.
-- The 15 reds are EXACTLY the 15 structural assertions; every premise (1-6) and every
-- invariance (22-28) was green on the first fire, which is the whole point of a de-dup.
--
-- BEFORE: the overstock rule
--     GREATEST(current_stock - GREATEST(COALESCE(velocity_instock, velocity_raw, 0) * 7, 5), 0)
--   was written VERBATIM in two objects:
--     · public.list_m2m_donors_v3        (42198fee) - NAMES the donors stitch_v3 may pull from
--     · public.resolve_supply_ladder_v3  (920b32d0) - rung 4, decides if m2m is satisfiable
--   Cody tolerated the mirror only because fixture 45 assertions 4-5 pinned them together.
--
-- AFTER: both read public.v_m2m_donor_surplus. The rule is written once.
--
-- ⛔⛔ THE ONE THING THIS MIGRATION MUST NOT DO, AND WHY THE VIEW HAS TWO EXCESS COLUMNS:
--   The two sites ROUND DIFFERENTLY and always have.
--     · list_m2m_donors_v3 casts EACH ROW to ::int (its RETURNS TABLE declares int), callers sum.
--     · resolve_supply_ladder_v3 sums the NUMERIC excess into v_donor_units (declared numeric)
--       and rounds ONCE, at v_av4 := LEAST(p_qty_needed, v_donor_units)::int.
--   Live at leg 150: 353 donor rows / 57 pods, 46 rows fractional, sum-of-rounded 2014 vs
--   rounded-of-sum 2012, and 17 of 57 pods disagree. Pointing both sites at ONE excess column
--   would silently move rung-4 availability on those 17 pods. That is a POLICY change and it
--   belongs to D-27(b) with its own Article-16 review - not to a de-duplication.
--   So the canonical view exposes BOTH: excess_exact (numeric) and excess_units (int).
--   Fixture 71 seqs 18-21 pin the columns, seq 24 pins the naming side's arithmetic and
--   seq 27 pins the ladder's, as NUMBERS. Converging them turns one of those red on purpose.
--
-- ⛔ WHAT THIS UNIT DELIBERATELY LEAVES ALONE (D-27(b), still parked):
--   the velocity TERM itself. `v_shelf_state.velocity_instock` is a hardcoded `NULL::numeric`
--   column (0 of 656 rows carry a value), so COALESCE(velocity_instock, velocity_raw, 0)
--   resolves to velocity_raw unconditionally and its first arm is DEAD CODE. The canonical
--   view carries that COALESCE forward BYTE-FOR-BYTE. Replacing it changes which machines
--   qualify as donors and needs the before/after donor-set diff the ruling asks for.
--
-- ⭐ GUARD IDIOM (Cody R1, re-used from DR-8 and D-28): a DO $guard$ block runs BEFORE each
--   CREATE OR REPLACE, because CREATE OR REPLACE does not replace across a differing
--   signature - it silently OVERLOADS (the repurpose_machine foot-gun, CLAUDE.md). It also
--   asserts pronargdefaults, because a lost DEFAULT breaks every short-arg caller (the Wave-2
--   confirm outage). A DO $post$ block re-asserts every post-condition INSIDE the same
--   transaction that made the change.
--
-- ⭐ THE LADDER IS EDITED BY NAMED SUBSTITUTION, NOT RETYPED. Its body is 16,996 characters
--   and only ~8 lines change; retyping it by hand is how a transcription error ships. The
--   substitution asserts the exact pre-image md5 (920b32d0...) and refuses on anything else,
--   asserts the pattern matched EXACTLY ONCE, and re-asserts the signature afterwards.

------------------------------------------------------------------------------
-- 1. THE CANONICAL OBJECT
------------------------------------------------------------------------------

CREATE VIEW public.v_m2m_donor_surplus AS
SELECT s.machine_id,
       s.machine_name,
       s.shelf_id,
       s.shelf_code,
       s.pod_product_id,
       s.current_stock,
       -- ⛔ D-27(b) territory: this COALESCE is carried forward byte-for-byte. Its first arm
       --    is dead code (velocity_instock is NULL::numeric for every row) but replacing it
       --    changes the donor set, so it changes in its OWN reviewed unit, never here.
       COALESCE(s.velocity_instock, s.velocity_raw, 0)::numeric                  AS velocity,
       GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)::numeric AS cover_floor,
       -- ⛔ TWO excess columns, deliberately. See the header: the two call sites round
       --    differently, on 17 of 57 live pods, and converging that is D-27(b) not D-27(a).
       (s.current_stock
        - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5))::numeric AS excess_exact,
       GREATEST(s.current_stock
                - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)::int AS excess_units
  FROM public.v_shelf_state s
 WHERE s.pod_product_id IS NOT NULL
   AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5);

COMMENT ON VIEW public.v_m2m_donor_surplus IS
  'PRD-110 D-27(a). CANONICAL definition of an m2m donor surplus: which shelves may donate '
  'stock to another machine, and how much they can spare. Read by list_m2m_donors_v3 (which '
  'uses excess_units, the per-row rounded integer) and by resolve_supply_ladder_v3 rung 4 '
  '(which uses excess_exact, the numeric, and rounds once at the end). ⛔ The two excess '
  'columns are NOT redundant - the two call sites have always rounded differently and they '
  'disagree on 17 of 57 live pods. Converging them moves rung-4 availability and is D-27(b), '
  'a policy change requiring Article-16 review. Fixture 71 seqs 18-21/24/27 pin this.';

-- S-268: REVOKE ALL ... FROM PUBLIC does NOT remove Supabase's schema default privileges.
-- anon must be named explicitly. The grant surface matches v_shelf_state exactly, which is
-- postgres / authenticated / service_role - anon has never been able to read shelf state.
REVOKE ALL ON public.v_m2m_donor_surplus FROM anon, authenticated;
GRANT SELECT ON public.v_m2m_donor_surplus TO authenticated, service_role;

------------------------------------------------------------------------------
-- 2. THE NAMING SIDE — list_m2m_donors_v3
------------------------------------------------------------------------------

DO $guard1$
DECLARE n_overloads int; v_args text; v_defs int; v_secdef boolean; v_md5 text;
BEGIN
  SELECT count(*) INTO n_overloads
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'list_m2m_donors_v3';
  IF n_overloads <> 1 THEN
    RAISE EXCEPTION 'D-27(a) GUARD: expected exactly 1 list_m2m_donors_v3, found % - CREATE OR REPLACE would OVERLOAD, not replace', n_overloads;
  END IF;

  SELECT pg_get_function_identity_arguments(p.oid), p.pronargdefaults, p.prosecdef, substr(md5(p.prosrc),1,8)
    INTO v_args, v_defs, v_secdef, v_md5
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'list_m2m_donors_v3';

  IF v_args <> 'p_pod_product_id uuid, p_exclude_machine_id uuid' THEN
    RAISE EXCEPTION 'D-27(a) GUARD: list_m2m_donors_v3 signature drifted to (%)', v_args;
  END IF;
  IF v_defs <> 1 THEN
    RAISE EXCEPTION 'D-27(a) GUARD: list_m2m_donors_v3 pronargdefaults is %, expected 1 - losing the DEFAULT on p_exclude_machine_id breaks every 1-arg caller', v_defs;
  END IF;
  IF v_secdef THEN
    RAISE EXCEPTION 'D-27(a) GUARD: list_m2m_donors_v3 is unexpectedly SECURITY DEFINER';
  END IF;
  IF v_md5 <> '42198fee' THEN
    RAISE EXCEPTION 'D-27(a) GUARD: list_m2m_donors_v3 prosrc md5 is %, expected 42198fee - the body changed under this migration, re-derive before applying', v_md5;
  END IF;
END $guard1$;

CREATE OR REPLACE FUNCTION public.list_m2m_donors_v3(
  p_pod_product_id     uuid,
  p_exclude_machine_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(donor_machine_id uuid, donor_shelf_id uuid, donor_shelf_code text,
               donor_machine_name text, current_stock integer, velocity numeric,
               cover_floor numeric, excess_units integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- D-27(a): the overstock rule is no longer written here. It lives in
  -- public.v_m2m_donor_surplus, which resolve_supply_ladder_v3 rung 4 also reads.
  -- ⛔ This side reads excess_units - the PER-ROW ROUNDED integer - because this function's
  --    RETURNS TABLE has always declared it int and callers sum the rounded values. The
  --    ladder reads the canonical view's exact numeric column instead and rounds once at the
  --    end. That asymmetry is real, is 17-of-57-pods wide, and is D-27(b)'s to settle.
  --    Fixture 71 seq 20/24 pin this side of it.
  -- ⛔ Do NOT name the exact column in this body, even in a comment: the migration's post-guard
  --    greps prosrc and (correctly) refuses to let this side read it.
  SELECT d.machine_id,
         d.shelf_id,
         d.shelf_code,
         d.machine_name,
         d.current_stock,
         d.velocity,
         d.cover_floor,
         d.excess_units
    FROM public.v_m2m_donor_surplus d
   WHERE d.pod_product_id = p_pod_product_id
     AND (p_exclude_machine_id IS NULL OR d.machine_id <> p_exclude_machine_id)
   -- Deterministic: biggest donor first, machine_id breaks ties so the same fleet state always
   -- picks the same donor. A non-total order here would make stitch_v3 non-reproducible.
   ORDER BY d.excess_units DESC,
            d.machine_id,
            d.shelf_id;
$function$;

-- CODY R2: this comment previously read "Predicate is a byte-for-byte replica of
-- resolve_supply_ladder_v3 rung 4; fixture 45 pins them together." CREATE OR REPLACE
-- PRESERVES comments, so without this the migration would ship a documented claim that
-- the duplication it just removed is still there.
COMMENT ON FUNCTION public.list_m2m_donors_v3(uuid, uuid) IS
  'PRD-110 P3.1c, de-duplicated by D-27(a) leg 150. Names the rung-4 overstock donors the '
  'ladder only counted. Shelf grain, ordered by excess DESC then machine_id (total order = '
  'reproducible donor choice). ⭐ The overstock predicate is NO LONGER a replica - it reads '
  'the canonical public.v_m2m_donor_surplus, which resolve_supply_ladder_v3 rung 4 also reads. '
  '⛔ This side takes excess_units (per-row rounded int); the ladder takes excess_exact '
  '(numeric, rounded once at the end). That asymmetry predates D-27(a), is 17-of-57-pods wide, '
  'and is D-27(b) to settle. Pinned by fixture 71 seqs 20/24 and fixture 45 assertions 4-5.';

------------------------------------------------------------------------------
-- 3. THE LADDER — rung 4, by named substitution
------------------------------------------------------------------------------

DO $guard2$
DECLARE
  n_overloads int; v_args text; v_defs int; v_secdef boolean;
  v_src text; v_md5 text; v_new text; v_hits int;
  c_pat  CONSTANT text := 'SELECT COALESCE\(SUM\(GREATEST\([\s\S]*?AND s\.current_stock > GREATEST\(COALESCE\(s\.velocity_instock, s\.velocity_raw, 0\) \* 7, 5\);';
  c_repl CONSTANT text :=
'SELECT COALESCE(SUM(d.excess_exact), 0),' || E'\n' ||
'         count(DISTINCT d.machine_id)' || E'\n' ||
'    INTO v_donor_units, v_donor_machines' || E'\n' ||
'    FROM public.v_m2m_donor_surplus d' || E'\n' ||
'   WHERE d.pod_product_id = p_pod_product_id' || E'\n' ||
'     AND d.machine_id <> p_machine_id;';
BEGIN
  SELECT count(*) INTO n_overloads
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'resolve_supply_ladder_v3';
  IF n_overloads <> 1 THEN
    RAISE EXCEPTION 'D-27(a) GUARD: expected exactly 1 resolve_supply_ladder_v3, found %', n_overloads;
  END IF;

  SELECT pg_get_function_identity_arguments(p.oid), p.pronargdefaults, p.prosecdef,
         p.prosrc, substr(md5(p.prosrc),1,8)
    INTO v_args, v_defs, v_secdef, v_src, v_md5
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'resolve_supply_ladder_v3';

  IF v_args <> 'p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_qty_needed integer, p_top_n integer' THEN
    RAISE EXCEPTION 'D-27(a) GUARD: resolve_supply_ladder_v3 signature drifted to (%)', v_args;
  END IF;
  IF v_defs <> 1 THEN
    RAISE EXCEPTION 'D-27(a) GUARD: resolve_supply_ladder_v3 pronargdefaults is %, expected 1', v_defs;
  END IF;
  IF v_secdef THEN
    RAISE EXCEPTION 'D-27(a) GUARD: resolve_supply_ladder_v3 is unexpectedly SECURITY DEFINER';
  END IF;
  -- ⛔ The pre-image pin. This migration edits a 16,996-character body by substitution; if the
  --    body is not the one it was written against, it must refuse rather than guess.
  --    ⚠️ resolve_supply_ladder_v3 is ALSO D-37's target. If D-37 lands first this md5 moves
  --    and this migration correctly refuses - re-derive the substitution, do not loosen this.
  IF v_md5 <> '920b32d0' THEN
    RAISE EXCEPTION 'D-27(a) GUARD: resolve_supply_ladder_v3 prosrc md5 is %, expected 920b32d0 - the body changed (D-37?), re-derive the rung-4 substitution before applying', v_md5;
  END IF;

  -- The substitution must match EXACTLY ONCE. Zero means the rule moved; two means the
  -- pattern is ambiguous and the edit would be non-deterministic.
  SELECT count(*) INTO v_hits FROM regexp_matches(v_src, c_pat, 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'D-27(a) GUARD: rung-4 pattern matched % times, expected exactly 1', v_hits;
  END IF;

  v_new := regexp_replace(v_src, c_pat, c_repl);

  IF v_new ~* 'velocity_instock' THEN
    RAISE EXCEPTION 'D-27(a) GUARD: velocity_instock survives the substitution - rung 4 was not its only use, re-scope';
  END IF;
  IF v_new !~ 'v_m2m_donor_surplus' THEN
    RAISE EXCEPTION 'D-27(a) GUARD: substitution did not install the canonical object';
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.resolve_supply_ladder_v3(
       p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid,
       p_qty_needed integer, p_top_n integer DEFAULT 5)
     RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO %L AS %L',
    'public', v_new);
END $guard2$;

-- CODY R2 (ladder side): the old comment advertised "No consumer yet - wiring into stitch_v3
-- is a later unit (D-22)" and said nothing about where rung 4's rule lives. Restate both.
COMMENT ON FUNCTION public.resolve_supply_ladder_v3(date, uuid, uuid, uuid, integer, integer) IS
  'PRD-110 P3.1b, rung 4 de-duplicated by D-27(a) leg 150. BUILD-SPEC line 88 substitution '
  'ladder: variant -> substitute -> alt_wh -> m2m -> spot_buy -> blocked_demand. READ-ONLY '
  'advisory (STABLE, writes nothing). Logs all six rungs with reasons; asserts LAW 5 (silent '
  'qty-0 forbidden). Excludes VOXSOURCE sentinel stock and nets WH availability off prior '
  'claims on the same plan_date. ⭐ Rung 4 no longer carries its own copy of the overstock '
  'rule - it reads the canonical public.v_m2m_donor_surplus, taking excess_exact (numeric) and '
  'rounding ONCE at v_av4, which is what makes it differ from list_m2m_donors_v3 on 17 of 57 '
  'pods. ⛔ Do not repoint it at excess_units: that is D-27(b), a policy change. Proven by '
  'golden fixtures 40, 45 and 71.';

------------------------------------------------------------------------------
-- 4. POST-CONDITIONS — asserted inside the same transaction that made the change
------------------------------------------------------------------------------

DO $post$
DECLARE
  v_donors_src text; v_ladder_src text; v_n int; v_defs int; v_args text;
  v_before numeric; v_after numeric;
BEGIN
  -- no accidental overloads
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname IN ('list_m2m_donors_v3','resolve_supply_ladder_v3');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'D-27(a) POST: expected exactly 2 procs, found % - an overload was created', v_n;
  END IF;

  SELECT p.prosrc INTO v_donors_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='list_m2m_donors_v3';
  SELECT p.prosrc INTO v_ladder_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='resolve_supply_ladder_v3';

  IF v_donors_src !~ 'v_m2m_donor_surplus' THEN RAISE EXCEPTION 'D-27(a) POST: donors does not read the canonical object'; END IF;
  IF v_donors_src ~  'v_shelf_state'       THEN RAISE EXCEPTION 'D-27(a) POST: donors still names v_shelf_state'; END IF;
  IF v_donors_src !~ 'excess_units'        THEN RAISE EXCEPTION 'D-27(a) POST: donors must read the ROUNDED column'; END IF;
  IF v_donors_src ~  'excess_exact'        THEN RAISE EXCEPTION 'D-27(a) POST: donors must NOT read the exact column - that is the D-27(b) convergence'; END IF;

  IF v_ladder_src !~ 'v_m2m_donor_surplus' THEN RAISE EXCEPTION 'D-27(a) POST: ladder does not read the canonical object'; END IF;
  IF v_ladder_src ~* 'velocity_instock'    THEN RAISE EXCEPTION 'D-27(a) POST: ladder still carries the inline rule'; END IF;
  IF v_ladder_src !~ 'excess_exact'        THEN RAISE EXCEPTION 'D-27(a) POST: ladder must read the EXACT column - reading excess_units would move rung-4 availability on 17 of 57 pods'; END IF;

  -- signatures survived
  SELECT p.pronargdefaults, pg_get_function_identity_arguments(p.oid) INTO v_defs, v_args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='list_m2m_donors_v3';
  IF v_defs <> 1 OR v_args <> 'p_pod_product_id uuid, p_exclude_machine_id uuid' THEN
    RAISE EXCEPTION 'D-27(a) POST: donors signature/defaults changed (% / %)', v_args, v_defs;
  END IF;
  SELECT p.pronargdefaults, pg_get_function_identity_arguments(p.oid) INTO v_defs, v_args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='resolve_supply_ladder_v3';
  IF v_defs <> 1 OR v_args <> 'p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_qty_needed integer, p_top_n integer' THEN
    RAISE EXCEPTION 'D-27(a) POST: ladder signature/defaults changed (% / %)', v_args, v_defs;
  END IF;

  -- the canonical object is not readable by anon (S-268)
  IF has_table_privilege('anon', 'public.v_m2m_donor_surplus', 'SELECT') THEN
    RAISE EXCEPTION 'D-27(a) POST: anon can read the canonical view - REVOKE did not take';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.v_m2m_donor_surplus', 'SELECT') THEN
    RAISE EXCEPTION 'D-27(a) POST: authenticated cannot read the canonical view - both call sites are SECURITY INVOKER and would break';
  END IF;

  -- ⭐ BEHAVIOUR: the de-dup moved no number. Fleet-wide donor excess under the LEGACY rule,
  --    transcribed literally, vs what the canonical object now reports.
  SELECT COALESCE(SUM(GREATEST(s.current_stock
           - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)), 0)
    INTO v_before
    FROM public.v_shelf_state s
   WHERE s.pod_product_id IS NOT NULL
     AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5);
  SELECT COALESCE(SUM(d.excess_exact), 0) INTO v_after FROM public.v_m2m_donor_surplus d;
  IF v_before <> v_after THEN
    RAISE EXCEPTION 'D-27(a) POST: fleet donor excess moved % -> % - this is not a refactor', v_before, v_after;
  END IF;

  -- ⭐ CODY R3: the ladder ships by named substitution, so the migration TEXT recorded in
  --    supabase_migrations.schema_migrations does NOT contain the body that shipped. Pin the
  --    result to a value a later leg can verify, and refuse if the substitution was a no-op.
  --    Both md5s are also written to the EXECUTION-LOG's sentinel block.
  IF substr(md5(v_ladder_src),1,8) = '920b32d0' THEN
    RAISE EXCEPTION 'D-27(a) POST: resolve_supply_ladder_v3 md5 did not move off 920b32d0 - the substitution was a no-op';
  END IF;
  RAISE NOTICE 'D-27(a) SHIPPED: list_m2m_donors_v3 md5 % · resolve_supply_ladder_v3 md5 % (was 42198fee / 920b32d0)',
    substr(md5(v_donors_src),1,8), substr(md5(v_ladder_src),1,8);
END $post$;
