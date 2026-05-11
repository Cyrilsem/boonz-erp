-- ═══════════════════════════════════════════════════════════════════════
-- phaseB_b12_repurpose_aware_first_sale
--
-- Bug: v_machine_first_sale (B.1.2) returned the earliest sale across all
-- eras of a machine. For repurposed machines (machines.repurposed_at IS
-- NOT NULL) this includes sales from the PRIOR identity, making the
-- new machine look old even though its current identity is days old.
--
-- Effect was that recently-repurposed machines like NISSAN-0804
-- (repurposed 2026-05-07) read as 130+ days mature and got DEAD/ROTATE
-- OUT signals across all slots instead of the intended RAMPING grace.
--
-- Fix: when repurposed_at IS NOT NULL, first_sale_at = COALESCE(
--   MIN(sale_after_repurpose), repurposed_at::timestamptz
-- ). Machines never repurposed keep all-time MIN as before.
--
-- After this view ships and the lifecycle eval re-runs, NISSAN-0804 and
-- 4 other recently-repurposed machines (ACTIVATE-2005, MPMCC-1054,
-- MPMCC-1058, IFLYMCC-1024) flip into RAMPING. Two repurposed machines
-- already past 30d (ALHQ-1016, WH2-1018) correctly stay mature.
--
-- Constitution articles in scope: 9, 12
-- ═══════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS public.v_machine_first_sale;

CREATE VIEW public.v_machine_first_sale AS
SELECT
  m.machine_id,
  CASE
    WHEN m.repurposed_at IS NOT NULL THEN
      COALESCE(
        (
          SELECT MIN(sh.transaction_date)
          FROM public.sales_history sh
          WHERE sh.machine_id = m.machine_id
            AND sh.transaction_date >= m.repurposed_at::timestamptz
            AND sh.delivery_status = 'Successful'
        ),
        m.repurposed_at::timestamptz
      )
    ELSE
      (
        SELECT MIN(sh.transaction_date)
        FROM public.sales_history sh
        WHERE sh.machine_id = m.machine_id
          AND sh.delivery_status = 'Successful'
      )
  END AS first_sale_at
FROM public.machines m;

ALTER VIEW public.v_machine_first_sale SET (security_invoker = true);

COMMENT ON VIEW public.v_machine_first_sale IS
  'First-sale-per-machine, repurpose-aware (B.12). For machines with repurposed_at set, returns first post-repurpose sale (or repurposed_at if none yet). Otherwise returns all-time MIN(sale). Used by evaluate-lifecycle to gate MACHINE_RAMPING signal.';
