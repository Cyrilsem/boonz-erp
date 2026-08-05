-- PRD-110 P3.1c / S-89 · list_m2m_donors_v3
--
-- WHY THIS EXISTS
-- The rung-4 overstock rule (`current_stock > GREATEST(velocity*7, 5)`) lived in exactly one
-- place: an inline aggregate inside resolve_supply_ladder_v3, which collapsed it to
-- `count(DISTINCT machine_id)` and `SUM(excess)`. A COUNT cannot name a donor, so no caller
-- could ever act on it (S-91). This names them, at shelf grain, ordered by excess.
--
-- ⛔ The predicate is replicated BYTE-FOR-BYTE from the ladder, including
--    COALESCE(velocity_instock, velocity_raw, 0). Per S-73 velocity_instock is NULL on all
--    656 shelves, so this runs on velocity_raw while appearing to prefer in-stock. That is a
--    KNOWN, DELIBERATE carry-over: re-tightening it is its own Cody-reviewed unit, never a
--    drive-by here. Parity with the ladder is the whole point of this function -- fixture 45
--    asserts the two agree, so any future divergence fails the suite instead of drifting.
--
-- LAW 6: v_shelf_state is the canonical shelf<->pod object. shelf_configurations carries no
--        pod_product_id (S-90) and is never joined by shelf_code (A01<->A1 landmine).
-- Read-only: STABLE + SECURITY INVOKER. Emits nothing.

CREATE OR REPLACE FUNCTION public.list_m2m_donors_v3(
  p_pod_product_id     uuid,
  p_exclude_machine_id uuid DEFAULT NULL
)
RETURNS TABLE (
  donor_machine_id   uuid,
  donor_shelf_id     uuid,
  donor_shelf_code   text,
  donor_machine_name text,
  current_stock      integer,
  velocity           numeric,
  cover_floor        numeric,
  excess_units       integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  SELECT s.machine_id,
         s.shelf_id,
         s.shelf_code,
         s.machine_name,
         s.current_stock,
         COALESCE(s.velocity_instock, s.velocity_raw, 0)::numeric,
         GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)::numeric,
         GREATEST(s.current_stock
                  - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)::int
    FROM public.v_shelf_state s
   WHERE s.pod_product_id = p_pod_product_id
     AND s.pod_product_id IS NOT NULL
     AND (p_exclude_machine_id IS NULL OR s.machine_id <> p_exclude_machine_id)
     AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)
   -- Deterministic: biggest donor first, machine_id breaks ties so the same fleet state always
   -- picks the same donor. A non-total order here would make stitch_v3 non-reproducible.
   ORDER BY GREATEST(s.current_stock
                     - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)::int DESC,
            s.machine_id,
            s.shelf_id;
$fn$;

COMMENT ON FUNCTION public.list_m2m_donors_v3(uuid, uuid) IS
'PRD-110 P3.1c. Names the rung-4 overstock donors the ladder only counted. Shelf grain, ordered
by excess DESC then machine_id (total order = reproducible donor choice). Predicate is a
byte-for-byte replica of resolve_supply_ladder_v3 rung 4; fixture 45 pins them together.';

REVOKE ALL ON FUNCTION public.list_m2m_donors_v3(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_m2m_donors_v3(uuid, uuid) TO authenticated, service_role;
