-- v_machine_health_signals: days_since_visit becomes delivery-based
-- (picked_up OR returned), never packed alone.
--
-- CS: "packed" is prep, not proof a driver was physically at the machine --
-- a dispatch can sit packed for days before it's actually driven out (or get
-- cancelled/re-planned after packing). The prior join also counted
-- `dispatched = true` as a visit, which is equally not a physical-presence
-- signal. Only `picked_up` (driver took stock off the truck at the machine)
-- or `returned` (driver brought stock back, also proof of a physical stop)
-- are delivery events. This is a real bug fix, not a tuning change: a
-- machine that was packed-but-never-driven would silently read as "recently
-- visited" and understate its own staleness (s_stale, days_since_visit>
-- stale_override_days hard override) in v_machine_priority.
--
-- Blast radius: v_machine_health_signals has exactly two consumers
-- (v_machine_priority, v_shelf_state) -- both just read the column, no
-- signature/type change, so both pick up the corrected value automatically.
--
-- Measured live (rolled back before this file was written): only 1 of 32
-- graded machines has a different days_since_visit under the new predicate
-- today (VOXMCC-1011-0101-B0: 0 -> 3), and it does not change that machine's
-- p_tier (already P1_RESTOCK via a hard override either way). This is a
-- going-forward correctness fix, not something with a visible fleet effect
-- in this snapshot.
--
-- Cody: approve, Articles 12 (forward-only, byte-guarded single-predicate
-- replace), 16 (this IS the canonical days_since_visit definition per
-- PRD-074 -- fixed at the source, not patched in a consumer).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_viewdef('public.v_machine_health_signals'::regclass, true) INTO v_def;
  IF md5(v_def) <> '04f872508079236e4c9baa3c3a43407c' THEN
    RAISE EXCEPTION 'v_machine_health_signals drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
    'AND (rd.picked_up = true OR rd.returned = true OR rd.dispatched = true OR rd.packed = true)',
    'AND (rd.picked_up = true OR rd.returned = true)');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'v_machine_health_signals: last_visit join predicate pattern not found';
  END IF;

  EXECUTE 'CREATE OR REPLACE VIEW public.v_machine_health_signals AS ' || v_new;
END $mig$;
