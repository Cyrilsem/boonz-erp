-- PRD-113 A6 — the trigger's Add-New arm must test what the PREDICATE tests.
--
-- THE DIVERGENCE
--   is_internal_move_dispatch() only counts an Add New as a pairing counterpart when it is
--   live work:
--       AND COALESCE(add_leg.cancelled, false) = false
--       AND COALESCE(add_leg.skipped,   false) = false
--       AND COALESCE(add_leg.include,   true)  = true
--
--   tg_mark_internal_move_pair's WHEN clause tested only `cancelled` and `is_m2m`. So an
--   Add New inserted with include = false or skipped = true would still fire the Add-arm and
--   stamp a Remove that the predicate itself does not consider paired.
--
--   That is not a cosmetic mismatch, because the predicate's FIRST live branch is
--   `WHEN COALESCE(rd.is_internal_move, false) THEN true`. The stored column OVERRIDES the
--   pairing test. An over-stamp therefore propagates straight through to the queue view and
--   the three approve RPCs, and a genuine warehouse return could drop out of the approval
--   queue on the strength of an Add New that was never going to happen.
--
--   Two objects answering one question, disagreeing at the edges — the exact Article 16
--   disease this PRD's predicate exists to cure. Fixed by making the trigger's gate a strict
--   subset of the predicate's, so the stamp can never claim more than the rule allows.
--
-- Article 12: fixed FORWARD. A2 and A5 are not edited.
-- ADDITIVE ONLY: one trigger re-created with a narrower WHEN clause. The function body,
-- the Remove arm, the alerts and every grant are untouched.

DROP TRIGGER IF EXISTS trg_mark_internal_move_pair ON public.refill_dispatching;
CREATE TRIGGER trg_mark_internal_move_pair
AFTER INSERT ON public.refill_dispatching
FOR EACH ROW
WHEN (NEW.action IN ('Remove', 'Add New', 'Add')
      AND NEW.boonz_product_id IS NOT NULL
      AND COALESCE(NEW.cancelled, false) = false
      AND COALESCE(NEW.is_m2m,    false) = false
      -- PRD-113 A6: mirror the predicate's liveness test on the counterpart leg. A
      -- de-scoped or skipped Add New is not a move partner and must not stamp anything.
      AND COALESCE(NEW.skipped,   false) = false
      AND COALESCE(NEW.include,   true)  = true)
EXECUTE FUNCTION public.tg_mark_internal_move_pair();

COMMENT ON FUNCTION public.tg_mark_internal_move_pair() IS
  'PRD-113. AFTER INSERT pair detector for refill_dispatching. Covers every writer '
  '(stitch, push_plan_to_dispatch, add_dispatch_row, the swap_* family, hand edits) with '
  'one implementation, because the Remove and its Add New counterpart are only both visible '
  'after the second of the pair lands. Never touches a settled leg or one carrying '
  'internal_move_cleared_at. A6: its WHEN clause is a strict subset of '
  'is_internal_move_dispatch()''s liveness test (not cancelled / not skipped / included), so '
  'the stored flag can never claim a pairing the canonical predicate would reject.';
