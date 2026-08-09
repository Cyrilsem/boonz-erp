-- PRD-113 A10 — the A9 trigger must not strand a multi-variant return.
--
-- wh_approve_remove_receipt_multivariant splits one Remove into child Remove rows, one per
-- variant, and calls receive_dispatch_line on each INSIDE THE SAME TRANSACTION. A9's trigger
-- evaluates the pairing predicate on each child, and a child carries the PARENT's shelf but a
-- VARIANT product id. If that variant happens to have an unrelated Add New on another shelf
-- of the same machine that day, the child is blocked, the whole call aborts, and the child
-- never exists - so there is nothing for clear_internal_move_flag to clear. The operator is
-- stuck with no recovery path, on a leg that is a GENUINE return.
--
-- The parent has already been through the A3 guard by then, so the children inherit a verdict
-- that has been made properly once. Exempt them by their own creation marker.
--
-- The failure this prevents is a refusal, not a bad credit - but a refusal with no way out is
-- still a defect, and this one lands on the warehouse manager mid-task.
--
-- Article 12: forward-only. ADDITIVE ONLY: one trigger re-created with a narrower WHEN clause.
-- The function body is untouched.

DROP TRIGGER IF EXISTS trg_block_internal_move_credit ON public.refill_dispatching;
CREATE TRIGGER trg_block_internal_move_credit
BEFORE UPDATE ON public.refill_dispatching
FOR EACH ROW
WHEN (NEW.item_added = true
      AND COALESCE(OLD.item_added, false) = false
      AND NEW.action = 'Remove'
      AND COALESCE(NEW.is_m2m, false) = false
      -- PRD-113 A10: multi-variant children inherit the parent's verdict, which
      -- wh_approve_remove_receipt_multivariant already took through the A3 guard.
      AND COALESCE(NEW.comment, '') NOT LIKE '[multi-variant child of %')
EXECUTE FUNCTION public.tg_block_internal_move_credit();
