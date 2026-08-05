-- PRD-110 P2.1 · v_shelf_instock_velocity_v3 · velocity_status three-valued-logic hole
--
-- CAUGHT BY: golden fixture 2 seq 8 ("I7: status ok implies a non-NULL velocity"), which went
-- 0 -> 2 between 09:51Z and 10:15Z on 2026-07-31. Bisected: NOT caused by leg 51's D-12 work
-- (which adds only views over pod_refills / pod_refills_shadow / blocked_demand). Reproduced
-- directly on the base view with no fixture involved.
--
-- THE DEFECT.
--   velocity_status = CASE WHEN si.machine_id IS NULL       THEN 'out_of_canonical_scope'
--                          WHEN a.stock_hours < w.floor_hours THEN 'below_floor'
--                          ELSE 'ok' END
--   When `stock_hours` is NULL — the series was NEVER observed in stock inside the window —
--   `NULL < 48.0` evaluates to NULL, not TRUE. The 'below_floor' branch does not fire and
--   control falls through to the OPTIMISTIC default 'ok'.
--
--   Meanwhile velocity_instock guards correctly (`stock_hours >= floor_hours` is also NULL, so
--   the value is NULL). The result is the contradiction the fixture names: status says the
--   series is healthy, and there is no velocity behind it.
--
-- ⭐ THE GENERAL LESSON: the VALUE guard and the STATUS guard were written against the same
--   column but with opposite NULL behaviour. A `>=` guard fails safe on NULL (no value); a `<`
--   guard fails OPEN on NULL (falls to the else branch). Wherever a status column classifies
--   what a value column computes, the two predicates must agree on NULL explicitly.
--
-- WHY 'below_floor' AND NOT A NEW STATUS. stock_hours NULL means zero observed in-stock hours,
-- which is genuinely below the 48h floor — the existing label is accurate. Adding a fourth
-- status value would also red fixture 2's `status_other` assertion, which requires the domain to
-- stay exactly {ok, below_floor, out_of_canonical_scope}. Correcting the predicate is both the
-- smaller and the more honest change.
--
-- BLAST RADIUS, MEASURED BEFORE APPLYING (not assumed):
--   · `engine_add_pod_v3` reads velocity_status from `v_shelf_instock_velocity_split_v3`, the
--     SHELF-grain sibling — NOT from this pod-grain view.
--   · That sibling has **0 violations across all 544 rows** (524 status='ok'), because its window
--     is anchored to max(weimi_device_status.snapshot_at) rather than now(). It is NOT patched
--     here: there is nothing to patch, and touching the engine's live input to fix a defect it
--     does not have would be scope drift.
--   · `engine_add_pod` v19 does not reference velocity_status at all.
--   · No other view in `public` references velocity_status.
--   ⇒ Zero engine impact, live or shadow. 2 rows change label, on one machine.
--
-- 📌 WHY IT SURFACED NOW: this view's window is `t_start = now() - 30 days`, so it slides
-- continuously. The last usable observation for those two series fell out of the window between
-- the two runs. The fixture did not become flaky — it became TRUE. Expect this invariant to be
-- intermittent until this fix lands, which is exactly why it is being fixed rather than pinned.
--
-- Article 12: forward-only, expression-level correction. Column list, order, types, reloptions
-- and grants all preserved. Anchored substitution with a hard refusal if the anchor moved.

DO $mig$
DECLARE
  v_def     text;
  v_new     text;
  v_anchor  CONSTANT text := 'WHEN a.stock_hours < w.floor_hours THEN ''below_floor''::text';
  v_fixed   CONSTANT text := 'WHEN a.stock_hours IS NULL OR a.stock_hours < w.floor_hours THEN ''below_floor''::text';
  v_opts    text;
BEGIN
  SELECT pg_get_viewdef(c.oid, true),
         array_to_string(c.reloptions, ', ')
    INTO v_def, v_opts
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_shelf_instock_velocity_v3';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'v_shelf_instock_velocity_v3 not found';
  END IF;

  -- Refuse to guess. If the anchor has moved, this migration must fail loudly rather than
  -- silently apply a no-op and report success (the class of failure that costs a whole leg).
  IF position(v_anchor in v_def) = 0 THEN
    RAISE EXCEPTION 'velocity_status anchor not found - view definition changed, refusing to patch blind';
  END IF;

  IF position('stock_hours IS NULL OR' in v_def) > 0 THEN
    RAISE EXCEPTION 'already guarded - refusing to double-apply';
  END IF;

  -- security_invoker must be restated: CREATE OR REPLACE VIEW with no WITH clause is not a
  -- safe way to inherit reloptions, and losing it would silently widen read access (Article 3).
  IF v_opts IS NULL OR position('security_invoker' in v_opts) = 0 THEN
    RAISE EXCEPTION 'expected security_invoker on this view, found: %', COALESCE(v_opts, '<none>');
  END IF;

  v_new := replace(v_def, v_anchor, v_fixed);

  EXECUTE format('CREATE OR REPLACE VIEW public.v_shelf_instock_velocity_v3 WITH (%s) AS %s',
                 v_opts, v_new);
END
$mig$;

COMMENT ON VIEW public.v_shelf_instock_velocity_v3 IS
  'PRD-110 P2.1 pod-grain in-stock velocity. ⛔ velocity_status classifies NULL stock_hours as '
  '''below_floor'' (fixed 2026-07-31 leg 51): a NULL is zero observed in-stock hours, and the '
  'pre-fix `stock_hours < floor_hours` predicate returned NULL there and fell through to ''ok''. '
  'Window is now()-anchored and slides continuously — unlike v_shelf_instock_velocity_split_v3, '
  'which anchors on max(weimi_device_status.snapshot_at) and is what engine_add_pod_v3 reads. '
  'Invariant pinned by golden fixture 2 seq 8.';
