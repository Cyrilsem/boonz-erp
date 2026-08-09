-- PRD-113 A1 — schema: refill_dispatching.is_internal_move
--
-- Live incident MC-2004-0100-O1, plan 2026-08-07: a swap that MOVES product between two
-- shelves OF THE SAME MACHINE produced Remove legs that landed in the warehouse
-- return-approval queue. Approving them would have credited the warehouse for units that
-- are physically still inside the machine — phantom stock. The warehouse manager caught it;
-- the previous occurrence was silently mishandled.
--
-- The return queue is "action=Remove AND wh_approved_at IS NULL" and had no concept of
-- "these units moved to another shelf, they are not coming back". This column is that
-- concept. It is additive and defaults to false, so every existing row keeps today's
-- meaning exactly.
--
-- ADDITIVE ONLY. No backfill here: A2 stamps new rows going forward, and the FE renders
-- legacy move-convention comments as display-only (PRD-113 fix 4).

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS is_internal_move boolean NOT NULL DEFAULT false;

-- Cody condition 5. The pairing rule is a heuristic; an operator's ruling is not. Without a
-- durable override, clearing the flag lasts only until the next 'Add New' for that product
-- lands and the trigger re-stamps it — a heuristic outranking a human, which is a defect.
-- These two columns are that override, and they are what the trigger and
-- mark_internal_move_legs skip on. Written only by clear_internal_move_flag().
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS internal_move_cleared_at timestamptz;
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS internal_move_cleared_by uuid;

COMMENT ON COLUMN public.refill_dispatching.is_internal_move IS
  'PRD-113. TRUE on a Remove leg whose units move to ANOTHER SHELF OF THE SAME MACHINE '
  '(an in-machine move), not back to the warehouse. Such a leg is excluded from the '
  'warehouse return-approval queue and every wh_approve_* RPC refuses it: there is nothing '
  'to credit, the units never left the machine. Distinct from is_m2m, which moves stock to a '
  'DIFFERENT machine. Set by tg_mark_internal_move_pair / mark_internal_move_legs; the live '
  'predicate is public.is_internal_move_dispatch().';

COMMENT ON COLUMN public.refill_dispatching.internal_move_cleared_at IS
  'PRD-113. Set by clear_internal_move_flag() when a human rules that this leg is a GENUINE '
  'warehouse return despite the pairing heuristic. Once set, is_internal_move_dispatch() '
  'returns false unconditionally and neither tg_mark_internal_move_pair nor '
  'mark_internal_move_legs will re-stamp the leg. A human decision outranks the heuristic.';

COMMENT ON COLUMN public.refill_dispatching.internal_move_cleared_by IS
  'PRD-113. The operator who cleared internal_move_cleared_at. Their reason is in '
  'write_audit_log via app.mutation_reason.';

-- The pairing lookup is (machine_id, dispatch_date, boonz_product_id) restricted to the
-- three actions that can form a move pair. Partial so it stays small on a 37k-row table.
CREATE INDEX IF NOT EXISTS idx_rd_internal_move_pair
  ON public.refill_dispatching (machine_id, dispatch_date, boonz_product_id, action)
  WHERE action IN ('Remove', 'Add New', 'Add');
