-- PRD-110 P4.4 migration B2 - admit the two spot-buy event types.
--
-- S-148 (leg 91): procurement_events.event_type is a CLOSED CHECK of 11 values.
-- create_spot_purchase_v3 emits 'spot_purchase_created' and
-- 'spot_purchase_task_autoclosed', neither of which was admitted, so the RPC
-- raised 23514 on its first real invocation. Caught by a smoke probe BEFORE the
-- fixture existed, which is why nothing half-applied reached the ledger.
--
-- This is ADDITIVE: the 11 incumbent values are re-stated verbatim and the
-- migration refuses to proceed if any of them would be lost. Reusing
-- 'goods_received' / 'task_collected' instead was rejected - it would make a
-- spot buy indistinguishable from a planned receive in the event stream, which
-- is precisely the signal P4.5's scoreboard needs.

DO $$
DECLARE
  v_def     text;
  v_missing text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
   WHERE conrelid = 'public.procurement_events'::regclass
     AND conname  = 'procurement_events_event_type_check';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'P4.4 B2 precondition failed: procurement_events_event_type_check not found';
  END IF;

  -- every incumbent value must be present BEFORE we touch it, so that the
  -- re-stated list below is provably a superset and not a guess.
  SELECT string_agg(x, ', ') INTO v_missing
    FROM unnest(ARRAY['po_created','po_line_edited','lines_appended','task_assigned',
                      'task_acknowledged','task_collected','task_cancelled','task_pending',
                      'task_reopened','goods_received','line_not_purchased']) AS x
   WHERE position('''' || x || '''' in v_def) = 0;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'P4.4 B2 ABORT: the live CHECK does not contain expected incumbent value(s) %. Re-read it before editing.', v_missing;
  END IF;
END $$;

ALTER TABLE public.procurement_events
  DROP CONSTRAINT procurement_events_event_type_check;

ALTER TABLE public.procurement_events
  ADD CONSTRAINT procurement_events_event_type_check
  CHECK (event_type = ANY (ARRAY[
    -- 11 incumbent values, verbatim
    'po_created', 'po_line_edited', 'lines_appended', 'task_assigned',
    'task_acknowledged', 'task_collected', 'task_cancelled', 'task_pending',
    'task_reopened', 'goods_received', 'line_not_purchased',
    -- PRD-110 P4.4 additions
    'spot_purchase_created', 'spot_purchase_task_autoclosed'
  ]));

DO $$
DECLARE
  v_def     text;
  v_missing text;
  v_fired   boolean := false;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
   WHERE conrelid = 'public.procurement_events'::regclass
     AND conname  = 'procurement_events_event_type_check';

  SELECT string_agg(x, ', ') INTO v_missing
    FROM unnest(ARRAY['po_created','po_line_edited','lines_appended','task_assigned',
                      'task_acknowledged','task_collected','task_cancelled','task_pending',
                      'task_reopened','goods_received','line_not_purchased',
                      'spot_purchase_created','spot_purchase_task_autoclosed']) AS x
   WHERE position('''' || x || '''' in v_def) = 0;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'P4.4 B2 FAILED: value(s) % absent from the rebuilt CHECK', v_missing;
  END IF;

  -- the CHECK must still be able to REFUSE. A constraint that admits everything
  -- is worse than none, and this is the cheap proof it did not become one.
  BEGIN
    INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
    VALUES ('PRD110-B2-PROBE', 'not_a_real_event_type', NULL, '{}'::jsonb);
  EXCEPTION WHEN check_violation THEN
    v_fired := true;
  END;

  IF NOT v_fired THEN
    RAISE EXCEPTION 'P4.4 B2 FAILED: the rebuilt CHECK did not refuse an invalid event_type';
  END IF;

  RAISE NOTICE 'P4.4 B2 OK: 13 values admitted, invalid values still refused';
END $$;
