-- PRD-072 P0: machine-readable bind-failure state on the dispatch line (Dara design 2026-07-04).
-- Distinct from pack_outcome: not_filled is a CONFIRMED outcome (driver attempted, no stock,
-- line travels resolved); bind_fail_reason is a RETRYABLE condition (this save attempt could
-- not bind a WH batch). Written only by pack_dispatch_line's fail-soft path; cleared on
-- successful pack or a not_filled resolution.
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS bind_fail_reason text
    CHECK (bind_fail_reason IS NULL OR bind_fail_reason IN
           ('no_stock','quarantined','inactive_batch','pinned_elsewhere')),
  ADD COLUMN IF NOT EXISTS bind_fail_at timestamptz;

COMMENT ON COLUMN public.refill_dispatching.bind_fail_reason IS
  'PRD-072: why the last pack attempt could not bind a WH batch (retryable; NULL = no outstanding failure). Set/cleared only by pack_dispatch_line.';
COMMENT ON COLUMN public.refill_dispatching.bind_fail_at IS
  'PRD-072: when the last failed bind attempt happened (triage/monitoring).';

-- Serves the monitoring query "which lines are bind-blocked today":
--   SELECT ... FROM refill_dispatching WHERE dispatch_date = X AND bind_fail_reason IS NOT NULL
CREATE INDEX IF NOT EXISTS idx_rd_bind_fail_open
  ON public.refill_dispatching (dispatch_date)
  WHERE bind_fail_reason IS NOT NULL;
