-- ═══════════════════════════════════════════════════════════════════════
-- phaseB_b1_lifecycle_reality_anchor
--
-- Repoints lifecycle scoring off planogram (frozen seed since April 2026)
-- onto weimi_aisle_snapshots (refreshed every ~6h). Converts slot_lifecycle
-- from a (machine, shelf) snapshot to a (machine, shelf, product) ledger
-- so rotated-out products keep their score history.
--
-- Constitution articles: 1, 2, 3, 7, 9, 12, 14
-- Cody verdict: ⚠️ Approve with revisions (CHANGELOG known-debt entry — done)
--
-- ⛔ SEQUENCING: do not apply until evaluate-lifecycle/index.ts diff is
-- staged for the same release. The new partial unique index will refuse
-- a second is_current=true row per (machine, shelf), so the OLD edge fn
-- upsert key (machine_id,shelf_id) will fail on first product rotation.
-- Apply order: migration → edge fn deploy → next cron tick.
-- ═══════════════════════════════════════════════════════════════════════

-- Pre-flight: abort if existing data already violates the new invariant.
DO $$
DECLARE v_violations integer;
BEGIN
  SELECT COUNT(*) INTO v_violations FROM (
    SELECT machine_id, shelf_id
    FROM public.slot_lifecycle
    WHERE archived = false
    GROUP BY machine_id, shelf_id
    HAVING COUNT(*) > 1
  ) x;
  IF v_violations > 0 THEN
    RAISE EXCEPTION
      'Pre-flight failed: % (machine_id, shelf_id) pair(s) already have multiple non-archived rows. Resolve before migrating.',
      v_violations;
  END IF;
END $$;

-- New columns. Existing rows backfill via defaults — no UPDATE needed.
ALTER TABLE public.slot_lifecycle
  ADD COLUMN IF NOT EXISTS is_current     boolean     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS rotated_out_at timestamptz,
  ADD COLUMN IF NOT EXISTS rotated_in_at  timestamptz NOT NULL DEFAULT now();

COMMENT ON COLUMN public.slot_lifecycle.is_current IS
  'TRUE = active product at this (machine, shelf). Exactly one is_current=true row per (machine_id, shelf_id) WHERE archived=false (enforced by partial unique index). When a product rotates out, this flips to FALSE and rotated_out_at is set; the row is preserved for history.';
COMMENT ON COLUMN public.slot_lifecycle.rotated_out_at IS
  'Timestamp when this product was replaced at this slot. NULL while is_current=true. Set only by evaluate-lifecycle.';
COMMENT ON COLUMN public.slot_lifecycle.rotated_in_at IS
  'Timestamp when this product first appeared in this slot per the lifecycle evaluator.';
COMMENT ON COLUMN public.slot_lifecycle.archived IS
  'TRUE = the slot itself ceased to exist (machine repurposed/decommissioned). Distinct from is_current=false which means the slot still exists with a different product. Set by repurpose_machine and add_new_machine.';

-- Constraint rotation: drop (machine, shelf) UK, add (machine, shelf, product) UK.
DO $$
DECLARE v_old_conname text;
BEGIN
  SELECT conname INTO v_old_conname
  FROM pg_constraint
  WHERE conrelid = 'public.slot_lifecycle'::regclass
    AND contype = 'u'
    AND conname = 'slot_lifecycle_machine_id_shelf_id_key';
  IF v_old_conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.slot_lifecycle DROP CONSTRAINT %I', v_old_conname);
  END IF;
END $$;

ALTER TABLE public.slot_lifecycle
  ADD CONSTRAINT slot_lifecycle_machine_shelf_product_uk
    UNIQUE (machine_id, shelf_id, pod_product_id);

-- Load-bearing invariant: at most one current product per live slot.
CREATE UNIQUE INDEX IF NOT EXISTS uq_slot_lifecycle_current_per_slot
  ON public.slot_lifecycle (machine_id, shelf_id)
  WHERE is_current = true AND archived = false;

-- Indexes for the per-slot history panel and product drill-downs.
CREATE INDEX IF NOT EXISTS idx_lifecycle_hist_slot_product_date
  ON public.lifecycle_score_history (machine_id, shelf_id, pod_product_id, snapshot_date DESC)
  WHERE scope = 'slot';

CREATE INDEX IF NOT EXISTS idx_lifecycle_hist_product_machine_date
  ON public.lifecycle_score_history (pod_product_id, machine_id, snapshot_date DESC)
  WHERE scope = 'slot';
