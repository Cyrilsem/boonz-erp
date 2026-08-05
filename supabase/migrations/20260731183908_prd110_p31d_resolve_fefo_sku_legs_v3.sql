-- PRD-110 P3.1d — FEFO SKU binding seam.
--
-- WHY A SEAM (⛔ S-91, leg 65): a branch that cannot be called on its own is a branch no
-- fixture can reach, and a branch no fixture reaches is unverified code. The pod->SKU
-- decision therefore lives here, directly callable and directly fixturable, exactly as
-- resolve_m2m_donor_legs_v3 does for rung 4. Same posture as that sibling: read-only,
-- STABLE, NOT SECURITY DEFINER (it writes nothing, so it needs no owner rights).
--
-- ⭐ CONVERGENCE, NOT A MIRROR (Article 16, and the lesson D-27 is open on): the batch walk
-- is NOT reimplemented here. public.wh_fefo_for_line is the canonical FEFO object and it
-- already encodes, in one place:
--     * LAW 6 FEFO ordering  - expiration_date ASC NULLS LAST, walking ALL batches;
--     * LAW 7 expiry iron rule - expiration_date >= p_plan_date, so stock that has expired
--       by the plan date can never be bound, i.e. never exits by assumption;
--     * pickability (Active, non-quarantined, stock > 0) via v_wh_pickable;
--     * reservation honouring (reserved_for_machine_id);
--     * netting of units already committed elsewhere on the same plan_date.
-- This function adds exactly ONE thing that object cannot do: it merges the per-SKU walks of
-- every Active variant of a pod into a SINGLE cross-SKU FEFO order. That merge is the new
-- logic; everything else is delegated.
--
-- ⛔ S-63 - sentinels are not supply. wh_fefo_for_line reads v_wh_pickable, which INCLUDES
-- the VOXSOURCE-* phantom rows (40 of 223 pickable rows live). resolve_supply_ladder_v3
-- excludes them from supply, so a binder that did not would name a batch the ladder had
-- already ruled phantom. Excluded here through the canonical predicate
-- _is_sentinel_wh_row_v3 - and excluded from the per-SKU ceiling too, not just from the
-- take, so committed-elsewhere netting is applied against REAL stock only.
--
-- ⛔ S-67 - assortment reads are DISTINCT and status='Active', machine-scoped OR global.
-- Identical predicate to resolve_supply_ladder_v3's own variants CTE, so the binder can
-- never consider a SKU the ladder did not count.
--
-- ⛔ LAW 5 - a unit this function cannot name a SKU for is returned as qty_unbound with a
-- NAMED reason. Never a silent NULL, never a silent qty-0.
--
-- ⭐ AUTHORITY SPLIT, stated so it is inspectable rather than implied: the LADDER decides HOW
-- MANY units are placeable; this function decides WHICH SKU they are. It never places more
-- than it was asked for, and it never overrides the ladder's count. The two objects use
-- deliberately different expiry horizons - the ladder counts stock pickable TODAY, this
-- binder binds only stock still in date ON THE PLAN DATE - so on any plan_date far in the
-- future the ladder can rule units placeable that no batch can name. That is reported as
-- qty_unbound, not silently reconciled.

CREATE OR REPLACE FUNCTION public.resolve_fefo_sku_legs_v3(
  p_plan_date      date,
  p_machine_id     uuid,
  p_shelf_id       uuid,
  p_pod_product_id uuid,
  p_qty            integer,
  p_rung           text DEFAULT 'variant'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_primary_wh uuid;
  v_wh_ids     uuid[];
  v_scope      text;
  v_n_variants int := 0;
  v_bound      int := 0;
  v_batches    int := 0;
  v_sentinels  int := 0;
  v_taken      jsonb := '{}'::jsonb;        -- bpid -> units already taken (per-SKU ceiling)
  v_legmap     jsonb := '{}'::jsonb;        -- bpid -> leg object
  v_order      uuid[] := ARRAY[]::uuid[];   -- FEFO order of first appearance
  v_legs       jsonb := '[]'::jsonb;
  v_status     text;
  v_reason     text;
  v_prev       jsonb;
  v_batch      jsonb;
  v_allow      int;
  b            record;
  k            uuid;
BEGIN
  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'resolve_fefo_sku_legs_v3: plan_date, machine_id and pod_product_id are all required';
  END IF;
  IF COALESCE(p_qty, 0) <= 0 THEN
    RAISE EXCEPTION 'resolve_fefo_sku_legs_v3: p_qty must be > 0 (got %)', p_qty;
  END IF;

  SELECT m.primary_warehouse_id INTO v_primary_wh
    FROM public.machines m WHERE m.machine_id = p_machine_id;

  -- Warehouse scope mirrors the LADDER'S OWN rung split, so the binder searches exactly the
  -- shelves of stock the rung was resolved against: rungs 1/2 are primary-WH rungs, rung 3
  -- ('alt_wh') is by definition every warehouse that is NOT the primary one.
  IF p_rung = 'alt_wh' THEN
    v_scope := 'alt';
    SELECT COALESCE(array_agg(DISTINCT w.warehouse_id), ARRAY[]::uuid[]) INTO v_wh_ids
      FROM public.v_wh_pickable w
     WHERE w.warehouse_id IS DISTINCT FROM v_primary_wh;
  ELSE
    v_scope  := 'primary';
    v_wh_ids := ARRAY[v_primary_wh];
  END IF;

  SELECT count(DISTINCT pm.boonz_product_id) INTO v_n_variants
    FROM public.product_mapping pm
   WHERE pm.pod_product_id = p_pod_product_id
     AND pm.status = 'Active'
     AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL);

  IF v_n_variants > 0 AND v_wh_ids <> ARRAY[]::uuid[] AND v_primary_wh IS NOT NULL THEN
    FOR b IN
      WITH variants AS (
        SELECT DISTINCT pm.boonz_product_id AS bpid
          FROM public.product_mapping pm
         WHERE pm.pod_product_id = p_pod_product_id
           AND pm.status = 'Active'
           AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
      ),
      walked AS (
        SELECT v.bpid, f.pick_rank, f.wh_inventory_id, f.warehouse_id, f.batch_id,
               f.expiration_date, f.warehouse_stock, f.committed_elsewhere,
               public._is_sentinel_wh_row_v3(f.batch_id, f.expiration_date) AS is_sentinel
          FROM variants v
          CROSS JOIN LATERAL public.wh_fefo_for_line(
                 p_machine_id, v.bpid, p_plan_date, p_qty::numeric, v_wh_ids) f
      )
      SELECT w.*,
             GREATEST(
               COALESCE(SUM(w.warehouse_stock) FILTER (WHERE NOT w.is_sentinel)
                        OVER (PARTITION BY w.bpid), 0) - w.committed_elsewhere, 0)::int AS sku_ceiling
        FROM walked w
       -- ⭐ THE ONE PIECE OF NEW LOGIC: a single FEFO order ACROSS every variant of the pod,
       --    so the oldest stock in the pod leaves first regardless of which SKU it is.
       --    pick_rank keeps each SKU's own canonical (created_at) order intact on ties.
       ORDER BY w.expiration_date ASC NULLS LAST, w.pick_rank, w.wh_inventory_id
    LOOP
      EXIT WHEN v_bound >= p_qty;

      IF b.is_sentinel THEN
        v_sentinels := v_sentinels + 1;
        CONTINUE;                       -- ⛔ S-63: phantom stock is never a bindable batch
      END IF;

      v_batches := v_batches + 1;

      v_allow := LEAST(
                   b.warehouse_stock::int,
                   GREATEST(b.sku_ceiling - COALESCE((v_taken->>b.bpid::text)::int, 0), 0),
                   p_qty - v_bound);
      CONTINUE WHEN v_allow <= 0;

      v_taken := jsonb_set(v_taken, ARRAY[b.bpid::text],
                   to_jsonb(COALESCE((v_taken->>b.bpid::text)::int, 0) + v_allow));

      v_batch := jsonb_build_object(
                   'wh_inventory_id',  b.wh_inventory_id,
                   'batch_id',         b.batch_id,
                   'warehouse_id',     b.warehouse_id,
                   'expiration_date',  b.expiration_date,
                   'qty_taken',        v_allow);

      v_prev := v_legmap -> (b.bpid::text);
      IF v_prev IS NULL THEN
        v_order  := v_order || b.bpid;
        v_legmap := jsonb_set(v_legmap, ARRAY[b.bpid::text], jsonb_build_object(
                      'boonz_product_id',          b.bpid,
                      'qty',                       v_allow,
                      -- the EARLIEST-expiry batch for this SKU: what the picker should pull
                      'preferred_wh_inventory_id', b.wh_inventory_id,
                      'earliest_expiry',           b.expiration_date,
                      'batches',                   jsonb_build_array(v_batch)));
      ELSE
        v_legmap := jsonb_set(v_legmap, ARRAY[b.bpid::text], jsonb_build_object(
                      'boonz_product_id',          b.bpid,
                      'qty',                       (v_prev->>'qty')::int + v_allow,
                      'preferred_wh_inventory_id', v_prev->'preferred_wh_inventory_id',
                      'earliest_expiry',           v_prev->'earliest_expiry',
                      'batches',                   (v_prev->'batches') || jsonb_build_array(v_batch)));
      END IF;

      v_bound := v_bound + v_allow;
    END LOOP;
  END IF;

  FOREACH k IN ARRAY v_order LOOP
    v_legs := v_legs || jsonb_build_array(v_legmap -> (k::text));
  END LOOP;

  -- Named outcomes, in the order that makes the FIRST true statement the most specific one.
  IF v_n_variants = 0 THEN
    v_status := 'unbound'; v_reason := 'no_active_variants';
  ELSIF v_primary_wh IS NULL THEN
    v_status := 'unbound'; v_reason := 'no_primary_warehouse';
  ELSIF v_wh_ids = ARRAY[]::uuid[] THEN
    v_status := 'unbound'; v_reason := 'no_warehouse_in_scope';
  ELSIF v_bound = 0 AND v_batches = 0 AND v_sentinels > 0 THEN
    v_status := 'unbound'; v_reason := 'all_batches_sentinel';
  ELSIF v_bound = 0 AND v_batches = 0 THEN
    v_status := 'unbound'; v_reason := 'no_pickable_batch_in_scope';
  ELSIF v_bound = 0 THEN
    v_status := 'unbound'; v_reason := 'fefo_ceiling_exhausted';
  ELSIF v_bound < p_qty THEN
    v_status := 'partial'; v_reason := 'fefo_short';
  ELSE
    v_status := 'ok';      v_reason := NULL;
  END IF;

  RETURN jsonb_build_object(
    'status',                   v_status,
    'plan_date',                p_plan_date,
    'machine_id',               p_machine_id,
    'shelf_id',                 p_shelf_id,
    'pod_product_id',           p_pod_product_id,
    'rung',                     p_rung,
    'warehouse_scope',          v_scope,
    'warehouse_ids',            to_jsonb(v_wh_ids),
    'qty_in',                   p_qty,
    'qty_bound',                v_bound,
    'qty_unbound',              p_qty - v_bound,
    'legs',                     v_legs,
    'n_legs',                   jsonb_array_length(v_legs),
    'unbound_reason',           v_reason,
    'variants_considered',      v_n_variants,
    'batches_taken',            v_batches,
    'sentinel_batches_skipped', v_sentinels,
    'fefo_rule',                'expiration_date ASC NULLS LAST, ALL batches walked, merged across ALL Active variants of the pod',
    'canonical_walker',         'public.wh_fefo_for_line',
    'expiry_law',               'LAW 7: wh_fefo_for_line binds only batches with expiration_date >= plan_date; expired stock never exits by assumption',
    'authority',                'the ladder decides HOW MANY units are placeable; this seam decides WHICH SKU they are');
END
$function$;

COMMENT ON FUNCTION public.resolve_fefo_sku_legs_v3(date, uuid, uuid, uuid, integer, text) IS
'PRD-110 P3.1d. Pod -> SKU FEFO binding seam. Merges the per-SKU canonical walks of
public.wh_fefo_for_line across every Active variant of a pod into one cross-SKU FEFO order
(expiration_date ASC NULLS LAST) and allocates p_qty over it, emitting one leg per SKU.
Read-only. Excludes VOXSOURCE sentinels (S-63). Unbindable units are returned as qty_unbound
with a named unbound_reason, never as a silent NULL (LAW 5).';

-- ⛔ CODY, binding revision (P3.1d review): a new function inherits EXECUTE for PUBLIC, which
-- reaches anon. This one returns warehouse batch ids, batch codes and expiry dates. The
-- sibling seams are inconsistent (list_m2m_donors_v3 / resolve_m2m_donor_legs_v3 are
-- anon-executable; resolve_supply_ladder_v3 / stitch_v3 are not) - match the TIGHTER pair.
REVOKE ALL ON FUNCTION public.resolve_fefo_sku_legs_v3(date, uuid, uuid, uuid, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_fefo_sku_legs_v3(date, uuid, uuid, uuid, integer, text)
  TO authenticated, service_role;
