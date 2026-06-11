-- PRD-018 BUG-E — variant mismatch: packed ≠ dispatch (outbound sibling of PRD-016 guardrail 2)
--
-- ROOT CAUSE (not a data anomaly — multi-default + split_pct is the fleet-wide design): stitch_pod_to_boonz
-- fans a multi-variant pod into one dispatch row PER resolved boonz variant by split_pct (e.g. Red Bull
-- pod → Regular 80% + Diet 20%). On a machine effectively stocking a single physical variant, the driver
-- packs that physical variant into BOTH rows, so a "Red Bull - Diet" dispatch row is physically filled with
-- Regular → packed ≠ dispatch. pack_dispatch_line can carry the actually-picked boonz_product_id (per-pick
-- override) but nothing flags when a multi-variant pod is packed WITHOUT an explicit variant selection.
--
-- FIX (this migration, backend half — WARN posture, mirrors guardrail 1 & 2): a NEW non-blocking BEFORE
-- UPDATE trigger firing on packed false→true. When the dispatch's pod_product resolves to >1 active boonz
-- variant for the machine AND no variant_action_log correction exists for the dispatch, it writes a
-- monitoring_alerts (warning) steering the FE to record_variant_correction (pin the actual packed variant).
-- NEW trigger (not a 2nd rewrite of pack_dispatch_line — respects the 24h-rewrite rule).
--
-- IMPROVEMENT over guardrail 2: the variant count includes GLOBAL-default mappings, not only machine-
-- specific ones. guardrail 2 counts `machine_id = NEW.machine_id` only, so a globally-mapped multi-variant
-- pod (Red Bull has no machine-specific rows) counts 0 and never fires. This counts the variants the
-- machine actually resolves to (machine-specific OR global-default), matching stitch_pod_to_boonz's pull.
--
-- FE escape hatch: record the packed variant at pack time via record_variant_correction with
-- action_type='dispatch_substitution' (an existing variant_action_log action_type) → Stax.
-- Read-only flag (no protected write beyond the monitoring_alerts ledger). Articles 1, 8, 12.

CREATE OR REPLACE FUNCTION public.flag_multivariant_pack_without_variant_confirmation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_variant_count int;
  v_has_correction boolean;
BEGIN
  IF NEW.pod_product_id IS NOT NULL
     AND NEW.action IN ('Refill','Add New')
     AND COALESCE(NEW.is_m2m, false) = false
     AND COALESCE(NEW.source_origin::text, 'warehouse') = 'warehouse'
  THEN
    -- Count the boonz variants this machine actually resolves to for the pod: machine-specific rows win,
    -- else global defaults (matches stitch_pod_to_boonz's pull_raw). This catches globally-mapped pods
    -- (e.g. Red Bull) that guardrail 2's machine_id-only count misses.
    SELECT count(DISTINCT boonz_product_id) INTO v_variant_count
    FROM public.product_mapping
    WHERE pod_product_id = NEW.pod_product_id
      AND status = 'Active'
      AND (machine_id = NEW.machine_id OR (machine_id IS NULL AND is_global_default = true));

    IF v_variant_count > 1 THEN
      SELECT EXISTS(
        SELECT 1 FROM public.variant_action_log
        WHERE refill_dispatching_id = NEW.dispatch_id
      ) INTO v_has_correction;

      IF NOT v_has_correction THEN
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES (
          'prd018_guardrail3_pack_variant_unconfirmed',
          'warning',
          jsonb_build_object(
            'dispatch_id', NEW.dispatch_id,
            'machine_id', NEW.machine_id,
            'pod_product_id', NEW.pod_product_id,
            'dispatch_boonz_product_id', NEW.boonz_product_id,
            'variant_count', v_variant_count,
            'shelf_id', NEW.shelf_id,
            'dispatch_date', NEW.dispatch_date,
            'message', 'A multi-variant pod_product was packed against the dispatch-resolved boonz variant without an explicit variant selection — packed physical variant may differ from the dispatch variant (BUG-E). Call record_variant_correction (action_type dispatch_substitution) to pin the actually-packed variant.'
          )
        );
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_flag_multivariant_pack_without_confirmation ON public.refill_dispatching;
CREATE TRIGGER trg_flag_multivariant_pack_without_confirmation
  BEFORE UPDATE ON public.refill_dispatching
  FOR EACH ROW
  WHEN (NEW.packed = true AND COALESCE(OLD.packed, false) = false)
  EXECUTE FUNCTION public.flag_multivariant_pack_without_variant_confirmation();
