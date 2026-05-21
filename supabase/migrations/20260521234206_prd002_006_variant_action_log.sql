-- ============================================================================
-- PRD-002 + PRD-006 — variant_action_log (append-only)
--
-- Source PRDs:
--   docs/prds/refill-pipeline/PRD-002-returns-split-by-variant-ui.md
--   docs/prds/refill-pipeline/PRD-006-dispatch-enforces-single-variant.md
--
-- Both PRDs need an append-only audit row for every human-driven variant
-- change. PRD-002's Decision says: "Reuse this same table for PRD-006
-- substitution captures." This migration ships that shared table.
--
-- Action vocabulary covers both PRDs:
--   - return_variant_change : driver changed the variant on a returned line
--                             (PRD-002 returns split UI)
--   - return_variant_split  : driver split a returned line across same-family
--                             variants (PRD-002 split-by-variant)
--   - dispatch_substitution : driver substituted a variant during picking
--                             when the planned variant was unavailable
--                             (PRD-006 substitution flow)
--   - dispatch_extra_variant: driver added a same-family variant not in the
--                             original plan (PRD-006 deviation)
--
-- All four share the same shape: who, when, which dispatch row, the original
-- variant, the new variant, qty, an optional reason_code, free text.
--
-- Append-only per Cody Article 7 (no UPDATE, no DELETE policies).
-- Non-protected table — boonz_products + this log are app-level support
-- infrastructure, not in Constitution Appendix A.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.variant_action_log (
  log_id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  action_type         text        NOT NULL CHECK (action_type IN (
                                    'return_variant_change',
                                    'return_variant_split',
                                    'dispatch_substitution',
                                    'dispatch_extra_variant'
                                  )),
  -- The dispatch/return row this action relates to. Nullable for actions that
  -- predate or sit outside a dispatch (rare; e.g. add-on captured at the
  -- machine without an existing line).
  refill_dispatching_id uuid      REFERENCES public.refill_dispatching(dispatch_id) ON DELETE SET NULL,
  machine_id          uuid        NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  -- For splits there may be multiple rows; for substitutions exactly one
  -- planned → one new. NULL on planned_variant when action is
  -- dispatch_extra_variant (driver added something not planned).
  planned_variant_id  uuid        REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  new_variant_id      uuid        NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  product_family_id   uuid        REFERENCES public.product_families(product_family_id) ON DELETE SET NULL,
  qty                 numeric     NOT NULL CHECK (qty > 0),
  reason_code         text,                                                        -- e.g. 'out_of_stock', 'damaged', 'driver_choice'
  free_text           text,                                                        -- optional driver note
  created_by          uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),

  -- Cross-family guard: actions on the variant axis must stay within the
  -- same product_family unless the action_type is dispatch_extra_variant
  -- (which allows brand-new on-the-fly additions). PRD-002 Decision:
  -- "Cross-family belongs in substitution flow, not this UI." Enforced here
  -- so neither FE can sneak a cross-family edit past the audit.
  CHECK (
    action_type = 'dispatch_extra_variant'
    OR planned_variant_id IS NULL
    OR planned_variant_id = new_variant_id  -- no-op edits surface for audit anyway
    OR product_family_id IS NOT NULL        -- explicit family link is mandatory
  )
);

COMMENT ON TABLE public.variant_action_log IS
  'PRD-002+006: append-only audit of every human-driven variant change on a '
  'return or a dispatch pick. Shared by both PRDs per their coupled Decisions. '
  'Brain consumes this to weight observed variant deviations into future plans; '
  'CS reads it in the admin substitution review screen.';

-- ── Indexes ─────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_val_machine_created
  ON public.variant_action_log (machine_id, created_at DESC);
COMMENT ON INDEX public.idx_val_machine_created IS
  'Per-machine timeline read — admin substitution review screen + brain lookback.';

CREATE INDEX IF NOT EXISTS idx_val_new_variant_created
  ON public.variant_action_log (new_variant_id, created_at DESC);
COMMENT ON INDEX public.idx_val_new_variant_created IS
  'Per-variant frequency read ("how often is Be Kind Dark substituted for PB?") — '
  'feeds the procurement signal per PRD-006 Decisions.';

CREATE INDEX IF NOT EXISTS idx_val_family_created
  ON public.variant_action_log (product_family_id, created_at DESC)
  WHERE product_family_id IS NOT NULL;

-- Reverse lookup from a specific dispatch row to its history
CREATE INDEX IF NOT EXISTS idx_val_dispatch
  ON public.variant_action_log (refill_dispatching_id)
  WHERE refill_dispatching_id IS NOT NULL;

-- ── RLS: append-only per Article 7 ──────────────────────────────────────────

ALTER TABLE public.variant_action_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS val_select_authenticated ON public.variant_action_log;
CREATE POLICY val_select_authenticated
  ON public.variant_action_log
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS val_insert_self ON public.variant_action_log;
CREATE POLICY val_insert_self
  ON public.variant_action_log
  FOR INSERT TO authenticated
  WITH CHECK (
    created_by IS NULL                            -- service_role / RPC writes
    OR created_by = (SELECT auth.uid())          -- self-attributed
  );

DROP POLICY IF EXISTS val_no_update ON public.variant_action_log;
CREATE POLICY val_no_update
  ON public.variant_action_log
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS val_no_delete ON public.variant_action_log;
CREATE POLICY val_no_delete
  ON public.variant_action_log
  FOR DELETE TO authenticated USING (false);

COMMIT;

-- ============================================================================
-- WIRE-UP CHECKLIST (deferred — owned by the PRD-002 and PRD-006 FE work)
--   - Returns split UI (PRD-002): on save, INSERT one row per resulting
--     variant line with action_type = 'return_variant_change' or
--     'return_variant_split'. Set product_family_id from
--     v_product_family_members.
--   - Picking substitution UI (PRD-006): on save, INSERT
--     action_type = 'dispatch_substitution' with planned_variant_id +
--     new_variant_id + reason_code from the picker. Use
--     'dispatch_extra_variant' for on-the-fly add-ons (planned_variant_id
--     NULL allowed for that action_type only).
--   - reconcile_intent_progress (in live DB) should read this table to
--     credit strategic intents whose REMOVE was satisfied by a substitution
--     within the intent's scope.
-- ============================================================================
