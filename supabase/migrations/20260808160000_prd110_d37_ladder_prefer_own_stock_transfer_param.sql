-- PRD-110 leg 153 - D-37, half 1 of 2: the DIAL.
--
-- CS ruling (PARKING-LOT, 2026-08-03 queue clear):
--   "D-37 -> BUILD PARAM `ladder_prefer_own_stock_transfer` AND DEFAULT TRUE: full-pod
--    own-stock transfer outranks substitution. Fixture 6 seq 22/25/26 re-baseline per the
--    parked note; the 3,017-unit stranded pool is the acceptance evidence."
--
-- This migration ships the dial ONLY. It changes no behaviour: nothing reads the column
-- yet. The engine half is a separate Cody-reviewed migration, and between the two the
-- restated fixture-6 assertions are RED on purpose - that red IS the LAW 1 proof.
--
-- DARA notes:
--   * public.refill_policy_params is a single-row config table (id = 1). No index is
--     warranted on a one-row relation and none is added.
--   * boolean NOT NULL DEFAULT true: CS ruled the default, so the existing row must carry
--     true the instant the column exists rather than a NULL that each reader re-interprets.
--   * Additive only. No column is dropped, retyped or renamed (LAW 3).
--   * No RLS change: this table's policies are untouched by this unit.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS ladder_prefer_own_stock_transfer boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.refill_policy_params.ladder_prefer_own_stock_transfer IS
  'D-37 (PRD-110). When true, resolve_supply_ladder_v3 tries rung 3 (alt_wh) BEFORE rung 2 '
  'for a shelf whose own pod is transferable IN FULL from a non-primary warehouse - i.e. '
  'moving your own stock outranks swapping the customer''s product, but only when the move '
  'covers the whole need. When false the BUILD-SPEC line 88 order is restored exactly. '
  'CS ruled DEFAULT TRUE. The rung LOG order is unaffected: all six rungs are still logged '
  '1..6 in spec order; only the TERMINAL choice moves.';

-- Read-back proof, in this same transaction, that the ruled default actually landed on the
-- live row rather than merely on the column definition.
DO $do$
DECLARE v_n int; v_true int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE ladder_prefer_own_stock_transfer)
    INTO v_n, v_true FROM public.refill_policy_params;
  IF v_n <> 1 OR v_true <> 1 THEN
    RAISE EXCEPTION 'D-37 dial did not land as ruled: % row(s), % carrying true', v_n, v_true;
  END IF;
END $do$;
