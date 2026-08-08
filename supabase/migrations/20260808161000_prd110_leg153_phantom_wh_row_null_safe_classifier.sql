-- PRD-110 leg 153 - UNIT A (LAW 8): the sentinel classifier was NULL-blind, and the FEFO
-- binder was therefore binding phantom stock into real dispatch legs.
--
-- HOW IT WAS FOUND. Fixture 6 was fired in isolation before D-37 touched anything and came
-- back 48/51 - a pre-existing red nobody had seen, because fixture 6 had not been fired
-- since leg 148's sweep. Seq 30, 31 and 38 are binder assertions; no D-37 work can move
-- them. LAW 8 therefore preempted the authorised unit.
--
-- THE DEFECT, exactly. public._is_sentinel_wh_row_v3 reads:
--     COALESCE(p_batch_id LIKE 'VOXSOURCE-%' AND p_expiration_date = DATE '2099-12-31', false)
-- It requires the NAME *and* the expiry. A warehouse row whose batch_id IS NULL and whose
-- expiration_date is the 2099-12-31 phantom marker evaluates NULL AND true = NULL, which
-- COALESCEs to FALSE: the row is classified REAL and the binder happily picks it. This is
-- S-289's family (a NULL makes a predicate vacuous) landing on the sentinel guard itself.
--
-- MEASURED LIVE at authoring time (public.v_wh_pickable):
--   * 45 rows carry expiration_date = 2099-12-31; only 40 of them are VOXSOURCE-named.
--   * The 5 unnamed ones hold 5,029 units, written 2026-08-05 22:18Z and 2026-08-08 08:42Z.
--   * No VOXSOURCE-named row carries any other expiry (40 of 40 are 2099-12-31), so widening
--     the shape test cannot lose a row the name test used to catch.
--   * The classifier catches 40 today and 45 after this migration; 5,029 units stop being
--     bindable by the v3 seam.
--
-- THE FIX. Two predicates, because these are genuinely two questions that happened to share
-- one implementation:
--   * _is_sentinel_wh_row_v3 is BYTE-UNTOUCHED. It is the authorisation scope of
--     drain_consumer_stock_phantom_v3, a SECURITY DEFINER RPC that zeroes stock on a
--     protected entity, and Cody deliberately narrowed that scope in its revision 1.
--     Widening a destructive RPC's reach is not this unit's to do.
--   * _is_phantom_wh_row_v3 is NEW and is the binder's question: may this row be bound into
--     a leg at all. Shape-keyed and NULL-safe on both limbs. It is a strict superset.
-- resolve_fefo_sku_legs_v3 switches to the new predicate. One anchor, substituted under the
-- S-291 guard; every other byte of the binder is as pg_get_functiondef returned it.
--
-- OUT OF SCOPE AND NAMED, NOT FIXED (LAW 10) - see the PARKING-LOT entry:
--   * public.wh_fefo_for_line filters no sentinels at all, and push_plan_to_dispatch,
--     receive_dispatch_line and record_actual_refill call it with NO guard of any kind.
--     That is a LIVE exposure, wider than PRD-110, and it needs CS plus its own fixture.
--   * The 5,029 phantom units themselves are a data question. Nothing is deleted here.

CREATE OR REPLACE FUNCTION public._is_phantom_wh_row_v3(p_batch_id text, p_expiration_date date)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  -- NULL-safe on BOTH limbs, deliberately. Either limb alone is sufficient evidence that the
  -- row is not real stock; requiring both is what let 5 rows through. COALESCE wraps each
  -- limb separately so an unknown batch name cannot poison a known expiry, or the reverse.
  SELECT COALESCE(p_expiration_date = DATE '2099-12-31', false)
      OR COALESCE(p_batch_id LIKE 'VOXSOURCE-%', false);
$fn$;

COMMENT ON FUNCTION public._is_phantom_wh_row_v3(text, date) IS
  'PRD-110 leg 153. Canonical "this warehouse row must never be bound into a dispatch leg" '
  'test. Strict superset of _is_sentinel_wh_row_v3, which stays the NARROWER, name-AND-expiry '
  'authorisation predicate for drain_consumer_stock_phantom_v3. Do not merge the two: one '
  'answers "may the binder pick this", the other answers "may a SECURITY DEFINER RPC destroy '
  'this", and the second must stay narrow.';

CREATE OR REPLACE FUNCTION public.resolve_fefo_sku_legs_v3(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_qty integer, p_rung text DEFAULT 'variant'::text)
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
               public._is_phantom_wh_row_v3(f.batch_id, f.expiration_date) AS is_sentinel
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
$function$
