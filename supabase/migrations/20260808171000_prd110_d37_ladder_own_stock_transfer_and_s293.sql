-- PRD-110 leg 155 - D-37 EXECUTED, and S-293 closed with it.
--
-- CS RULING: "D-37 -> BUILD PARAM `ladder_prefer_own_stock_transfer` AND DEFAULT TRUE:
-- full-pod own-stock transfer outranks substitution."
--
-- TWO changes, in ONE reviewed unit, because they are two edits to the same body and
-- splitting them would leave the ladder half-restated between two migrations:
--
--   (a) D-37. The TERMINAL choice moves: when the dial is true and rung 3 covers the
--       WHOLE need, alt_wh outranks substitute. A PARTIAL transfer does not - it still
--       falls through to rung 2, because half a transfer plus a driver leg is not what
--       CS ruled for. The rung LOG is untouched: all six rungs are still logged 1..6 in
--       BUILD-SPEC order, so the ladder still shows what it passed over.
--
--   (b) S-293 (raised OPEN at leg 154, a BINDING RIDER on this unit). The supply base
--       classified sentinels with an inline, name-only filter and called neither
--       canonical helper. `NULL NOT LIKE ...` is NULL and `NULL LIKE ...` is NULL, so a
--       NULL-batch row was excluded from the real sums AND from the sentinel sum: it
--       landed in NO bucket. Live, that hid genuine stock from the ladder's supply base
--       and excluded phantom stock by accident rather than by rule. The two buckets are
--       now a true partition over `public._is_phantom_wh_row_v3`.
--
-- ⛔ The helper this now calls is the BINDER's predicate (leg 154), deliberately NOT the
--    sibling `_is_sentinel_wh_row_v3`, which is the authorisation scope of a destructive
--    SECURITY DEFINER RPC. The two are disjoint by design and converging them is a
--    REFUSAL, not a cleanup - see RPC_REGISTRY.md and the leg-154 parking-lot entry.
--
-- LAW 3 / LAW 4: versioned in place by CREATE OR REPLACE, no signature change, STABLE and
-- SECURITY INVOKER both unchanged, no DML on anything. Fixture 6 (restated at
-- 20260808170000) and fixture 44 are the proof; fixture 6 is RED until this lands.

-- ---------------------------------------------------------------------------
-- PRE-FLIGHT. Refuse rather than half-apply.
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'refill_policy_params'
                    AND column_name = 'ladder_prefer_own_stock_transfer') THEN
    RAISE EXCEPTION 'D-37 dial is absent - apply 20260808160000 (the parked dial migration) first';
  END IF;
  IF to_regprocedure('public._is_phantom_wh_row_v3(text,date)') IS NULL THEN
    RAISE EXCEPTION 'S-293 rider needs the leg-154 canonical predicate; it is absent';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'resolve_supply_ladder_v3'
        AND pronamespace = 'public'::regnamespace) <> '056cca45077bb00f31ab663409d4c573' THEN
    RAISE EXCEPTION 'the ladder body is not the reviewed pre-image - refusing to overwrite an unknown body';
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.resolve_supply_ladder_v3(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_qty_needed integer, p_top_n integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_primary_wh    uuid;    v_secondary_wh uuid;
  v_op_model      text;    v_machine_name text;
  v_gross_primary numeric := 0;  v_gross_other numeric := 0;  v_sentinel numeric := 0;
  v_claimed       numeric := 0;
  v_net_primary   numeric := 0;  v_net_other   numeric := 0;
  v_variants      int     := 0;
  v_wh_allowed    boolean := true;
  v_ladder        jsonb   := '[]'::jsonb;
  v_rung          text    := NULL;
  v_rung_no       int     := NULL;
  v_qty           int     := 0;
  v_payload       jsonb   := '{}'::jsonb;
  -- ⛔ S-85 (PRD-110 leg 63): these were ONE `v_sub record`. A PL/pgSQL record that is
  -- never assigned has an INDETERMINATE tuple structure, and the rung-2 LOG entry below
  -- references its fields unconditionally. When rung 1 is satisfiable the rung-2 SELECT
  -- INTO never runs, so every satisfiable call raised 55000 "record v_sub is not assigned
  -- yet" -- the ladder threw on its HAPPIEST path. A CASE guard cannot prevent this:
  -- PL/pgSQL must resolve the record's structure to build the expression, whichever
  -- branch is taken. Scalars are NULL-initialised, so the failure mode is removed by
  -- construction rather than guarded against.
  v_sub_pod_id    uuid;    v_sub_name      text;
  v_sub_category  text;    v_sub_cat_match boolean;
  v_sub_cs_review boolean; v_sub_stock     numeric;
  v_sub_margin    numeric; v_sub_reason    text;
  v_sat1 boolean := false; v_sat2 boolean := false; v_sat3 boolean := false;
  v_sat4 boolean := false; v_sat5 boolean := false;
  v_av1 int := 0; v_av3 int := 0; v_av4 int := 0;
  v_sub_tried     boolean := false;
  v_donor_units   numeric := 0;  v_donor_machines int := 0;
  v_cost          numeric;
  v_preauth_cap   numeric := 15.0;   -- parked default (BUILD-SPEC P4.4: snacks/drinks <= AED 15)
  -- D-37 (CS ruling, DEFAULT TRUE): a full-cover transfer of the shelf's OWN pod from a
  -- non-primary warehouse outranks rewriting the shelf to a different product.
  v_prefer_own    boolean := false;
  v_own_full      boolean := false;
  v_t0            timestamptz := clock_timestamp();
BEGIN
  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL OR p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'resolve_supply_ladder_v3: plan_date, machine_id, shelf_id and pod_product_id are all required';
  END IF;
  IF COALESCE(p_qty_needed, 0) <= 0 THEN
    RAISE EXCEPTION 'resolve_supply_ladder_v3: p_qty_needed must be > 0 (got %); a ladder call with no demand is a caller bug, not a blocked gap', p_qty_needed;
  END IF;

  SELECT m.primary_warehouse_id, m.secondary_warehouse_id, m.operating_model, m.official_name
    INTO v_primary_wh, v_secondary_wh, v_op_model, v_machine_name
    FROM public.machines m WHERE m.machine_id = p_machine_id;
  IF v_machine_name IS NULL THEN
    RAISE EXCEPTION 'resolve_supply_ladder_v3: machine % not found', p_machine_id;
  END IF;

  -- DATA-SOURCE LAW: partner_managed machines carry no boonz_wh edges, so the two
  -- warehouse rungs are not merely empty for them, they are inapplicable. Recorded as
  -- such rather than as "no stock", which would read as a procurement gap.
  v_wh_allowed := (COALESCE(v_op_model, 'fully_managed') <> 'partner_managed');

  -- D-37 DIAL, read once from the single-row policy table and defaulted defensively: a
  -- missing row must never make the rung order depend on NULL.
  SELECT COALESCE(pp.ladder_prefer_own_stock_transfer, false) INTO v_prefer_own
    FROM public.refill_policy_params pp ORDER BY pp.id LIMIT 1;
  v_prefer_own := COALESCE(v_prefer_own, false);

  ---------------------------------------------------------------------------
  -- SUPPLY BASE. Variants deduped BEFORE any stock is summed: a pod carrying both a
  -- global and a machine-specific product_mapping row would otherwise have its stock
  -- counted twice (the documented product_mapping fan-out anti-pattern).
  --
  -- S-293 (PRD-110 leg 154, closed at leg 155): these three buckets used an INLINE
  -- name-only test. A row with a NULL batch_id then evaluated NULL on BOTH the real
  -- filter and the phantom filter, so it landed in NO bucket at all - real stock went
  -- silently missing from the supply base AND phantom stock was excluded by accident
  -- rather than by rule. The canonical NULL-safe predicate makes the two buckets a true
  -- partition: every pickable row is counted exactly once, as real or as phantom.
  ---------------------------------------------------------------------------
  WITH variants AS (
    SELECT DISTINCT pm.boonz_product_id
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = p_pod_product_id
       AND pm.status = 'Active'
       AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
  )
  SELECT COALESCE(SUM(w.warehouse_stock) FILTER (
           WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
             AND w.warehouse_id = v_primary_wh), 0),
         COALESCE(SUM(w.warehouse_stock) FILTER (
           WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
             AND w.warehouse_id IS DISTINCT FROM v_primary_wh), 0),
         COALESCE(SUM(w.warehouse_stock) FILTER (
           WHERE public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)), 0),
         (SELECT count(*) FROM variants)
    INTO v_gross_primary, v_gross_other, v_sentinel, v_variants
    FROM variants vr
    LEFT JOIN public.v_wh_pickable w
           ON w.boonz_product_id = vr.boonz_product_id
          AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = p_machine_id);

  -- Prior claims on the SAME pod for the SAME plan_date, excluding this shelf's own line.
  SELECT COALESCE(SUM(pr.qty), 0) INTO v_claimed
    FROM public.pod_refills pr
   WHERE pr.plan_date = p_plan_date
     AND pr.pod_product_id = p_pod_product_id
     AND pr.shelf_id IS DISTINCT FROM p_shelf_id;

  -- Allocation model: claims consume the primary WH first, then spill to other WHs.
  -- Named in the output so it is an inspectable assumption, not a hidden one.
  v_net_primary := GREATEST(v_gross_primary - v_claimed, 0);
  v_net_other   := GREATEST(v_gross_other - GREATEST(v_claimed - v_gross_primary, 0), 0);

  IF NOT v_wh_allowed THEN
    v_net_primary := 0;
    v_net_other   := 0;
  END IF;

  ---------------------------------------------------------------------------
  -- RUNG AVAILABILITY. Every rung is evaluated and logged; the terminal rung is the
  -- FIRST satisfiable one in BUILD-SPEC order. The expensive selector (rung 2) is the
  -- only one short-circuited, and when skipped it says so explicitly.
  ---------------------------------------------------------------------------
  v_av1  := LEAST(p_qty_needed, v_net_primary)::int;
  v_sat1 := (v_av1 > 0);

  -- D-37: rung 3's availability is computed BEFORE rung 2 so the expensive substitute
  -- selector can be short-circuited when a full-cover own-stock transfer already outranks
  -- it. The LOG order is untouched - all six rungs are still logged 1..6 in BUILD-SPEC
  -- order below, and only the TERMINAL choice moves.
  v_av3  := LEAST(p_qty_needed, v_net_other)::int;
  v_sat3 := (v_av3 > 0);
  v_own_full := (v_prefer_own AND v_sat3 AND v_av3 >= p_qty_needed);

  IF NOT v_sat1 AND NOT v_own_full THEN
    v_sub_tried := true;
    BEGIN
      SELECT s.pod_product_id, s.pod_product_name, s.product_category, s.category_match,
             s.requires_cs_review, s.wh_stock_units, s.unit_margin, s.reason
        INTO v_sub_pod_id, v_sub_name, v_sub_category, v_sub_cat_match,
             v_sub_cs_review, v_sub_stock, v_sub_margin, v_sub_reason
        FROM public.find_substitutes_for_shelf_v3(
               p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_top_n, 100) s
       ORDER BY s.rank
       LIMIT 1;
      v_sat2 := (v_sub_pod_id IS NOT NULL AND COALESCE(v_sub_stock, 0) > 0);
    EXCEPTION WHEN OTHERS THEN
      v_sat2 := false;
    END;
  END IF;

  SELECT COALESCE(SUM(d.excess_exact), 0),
         count(DISTINCT d.machine_id)
    INTO v_donor_units, v_donor_machines
    FROM public.v_m2m_donor_surplus d
   WHERE d.pod_product_id = p_pod_product_id
     AND d.machine_id <> p_machine_id;
  v_av4  := LEAST(p_qty_needed, v_donor_units)::int;
  v_sat4 := (v_av4 > 0);

  SELECT pp.purchasing_cost INTO v_cost
    FROM public.pod_products pp WHERE pp.pod_product_id = p_pod_product_id;
  v_sat5 := (v_cost IS NOT NULL);

  ---------------------------------------------------------------------------
  -- TERMINAL RUNG = first satisfiable, in spec order.
  ---------------------------------------------------------------------------
  IF v_sat1 THEN
    v_rung := 'variant'; v_rung_no := 1; v_qty := v_av1;
    v_payload := jsonb_build_object('warehouse_id', v_primary_wh, 'action', 'Refill',
                                    'net_available', v_net_primary, 'variants_considered', v_variants);
  ELSIF v_own_full THEN
    -- D-37: moving your own stock outranks swapping the customer's product, but ONLY when
    -- the move covers the whole need. A partial transfer still falls through to rung 2.
    v_rung := 'alt_wh'; v_rung_no := 3; v_qty := v_av3;
    v_payload := jsonb_build_object('from_warehouse', 'non-primary', 'to_warehouse', v_primary_wh,
                                    'secondary_warehouse_id', v_secondary_wh,
                                    'net_available', v_net_other, 'action', 'Transfer',
                                    'preferred_over_substitute', true,
                                    'rule', 'D-37 ladder_prefer_own_stock_transfer',
                                    'note', 'auto-transfer line; the leg itself is emitted by stitch_v3, not here');
  ELSIF v_sat2 THEN
    v_rung := 'substitute'; v_rung_no := 2;
    v_qty := LEAST(p_qty_needed, v_sub_stock)::int;
    v_payload := jsonb_build_object('substitute_pod_product_id', v_sub_pod_id,
                                    'substitute_name', v_sub_name,
                                    'product_category', v_sub_category,
                                    'category_match', v_sub_cat_match,
                                    'requires_cs_review', v_sub_cs_review,
                                    'unit_margin', v_sub_margin,
                                    'selector', 'find_substitutes_for_shelf_v3',
                                    'action', 'Add New');
  ELSIF v_sat3 THEN
    v_rung := 'alt_wh'; v_rung_no := 3; v_qty := v_av3;
    v_payload := jsonb_build_object('from_warehouse', 'non-primary', 'to_warehouse', v_primary_wh,
                                    'secondary_warehouse_id', v_secondary_wh,
                                    'net_available', v_net_other, 'action', 'Transfer',
                                    'note', 'auto-transfer line; the leg itself is emitted by stitch_v3, not here');
  ELSIF v_sat4 THEN
    v_rung := 'm2m'; v_rung_no := 4; v_qty := v_av4;
    v_payload := jsonb_build_object('donor_machines', v_donor_machines, 'donor_excess_units', v_donor_units,
                                    'action', 'M2M',
                                    'note', 'overstock donors identified at pod grain; SKU-level leg splitting is P3.2');
  ELSIF v_sat5 THEN
    v_rung := 'spot_buy'; v_rung_no := 5; v_qty := p_qty_needed;
    v_payload := jsonb_build_object('unit_cost', v_cost, 'preauth_cap', v_preauth_cap,
                                    'within_preauth', (v_cost <= v_preauth_cap),
                                    'action', 'SpotBuy',
                                    'note', 'CANDIDATE only. The pre-auth cap is a PARKED CS param; execution is create_spot_purchase_v3 in P4.4');
  ELSE
    v_rung := 'blocked_demand'; v_rung_no := 6; v_qty := 0;
    v_payload := jsonb_build_object('qty_blocked', p_qty_needed,
                                    'reason', CASE WHEN NOT v_wh_allowed THEN 'routing_gap'
                                                   WHEN v_sentinel > 0     THEN 'blocked_no_wh'
                                                   ELSE 'substitution_exhausted' END,
                                    'action', 'Blocked',
                                    'note', 'every rung exhausted; this is a REAL procurement gap, not a silent drop');
  END IF;

  ---------------------------------------------------------------------------
  -- THE LADDER LOG. All six rungs, always, in order, each with an explicit reason.
  ---------------------------------------------------------------------------
  v_ladder :=
    jsonb_build_array(
      jsonb_build_object(
        'rung_no', 1, 'rung', 'variant', 'attempted', true,
        'satisfiable', v_sat1, 'qty_available', v_av1,
        'reason', CASE
          WHEN NOT v_wh_allowed THEN 'N/A: partner_managed machine has no boonz_wh sourcing edge'
          WHEN v_sat1 THEN format('%s net unit(s) pickable at the primary WH across %s deduped variant(s), after %s unit(s) already claimed by this plan_date',
                                  v_net_primary::int, v_variants, v_claimed::int)
          WHEN v_gross_primary > 0 THEN format('%s gross primary-WH unit(s) exist but %s are already claimed by this plan_date, leaving 0 net',
                                  v_gross_primary::int, v_claimed::int)
          WHEN v_sentinel > 0 THEN format('no REAL primary-WH stock; %s phantom unit(s) excluded by _is_phantom_wh_row_v3 (VOXSOURCE name or the 2099-12-31 marker)', v_sentinel::int)
          ELSE 'no primary-WH stock for any variant of this pod' END,
        'detail', jsonb_build_object('gross_real_primary', v_gross_primary, 'claimed_units', v_claimed,
                                     'net_primary', v_net_primary, 'variants', v_variants)),
      jsonb_build_object(
        'rung_no', 2, 'rung', 'substitute', 'attempted', v_sub_tried,
        'satisfiable', v_sat2, 'qty_available', CASE WHEN v_sat2 THEN LEAST(p_qty_needed, v_sub_stock)::int ELSE 0 END,
        'reason', CASE
          WHEN NOT v_sub_tried AND v_sat1 THEN 'not reached: rung 1 already satisfiable'
          WHEN NOT v_sub_tried THEN format('not reached: D-37 ranks a full own-stock transfer above substitution, and rung 3 covers all %s unit(s) needed', p_qty_needed)
          WHEN v_sat2 THEN format('find_substitutes_for_shelf_v3 rank 1 = %s (%s), category_match=%s',
                                  v_sub_name, v_sub_category, v_sub_cat_match)
          ELSE 'find_substitutes_for_shelf_v3 returned no candidate holding stock' END,
        'detail', jsonb_build_object('selector', 'find_substitutes_for_shelf_v3', 'top_n', p_top_n)),
      jsonb_build_object(
        'rung_no', 3, 'rung', 'alt_wh', 'attempted', true,
        'satisfiable', v_sat3, 'qty_available', v_av3,
        'reason', CASE
          WHEN NOT v_wh_allowed THEN 'N/A: partner_managed machine has no boonz_wh sourcing edge'
          WHEN v_sat3 AND v_own_full THEN format('%s net unit(s) at a non-primary warehouse, transferable IN FULL - D-37 ranks this ahead of substitution', v_net_other::int)
          WHEN v_sat3 THEN format('%s net unit(s) at a non-primary warehouse, transferable', v_net_other::int)
          WHEN v_sentinel > 0 AND v_gross_other = 0 THEN format('no REAL stock at any other warehouse; %s sentinel unit(s) excluded as phantom', v_sentinel::int)
          ELSE 'no net stock at any other warehouse' END,
        'detail', jsonb_build_object('gross_real_other', v_gross_other, 'net_other', v_net_other,
                                     'secondary_warehouse_id', v_secondary_wh)),
      jsonb_build_object(
        'rung_no', 4, 'rung', 'm2m', 'attempted', true,
        'satisfiable', v_sat4, 'qty_available', v_av4,
        'reason', CASE
          WHEN v_sat4 THEN format('%s sibling machine(s) hold %s unit(s) above a 7-day cover floor', v_donor_machines, v_donor_units::int)
          ELSE 'no sibling machine holds this pod above its 7-day cover floor' END,
        'detail', jsonb_build_object('donor_machines', v_donor_machines, 'donor_excess_units', v_donor_units,
                                     'overstock_rule', 'current_stock > GREATEST(velocity*7, 5)')),
      jsonb_build_object(
        'rung_no', 5, 'rung', 'spot_buy', 'attempted', true,
        'satisfiable', v_sat5, 'qty_available', CASE WHEN v_sat5 THEN p_qty_needed ELSE 0 END,
        'reason', CASE
          WHEN v_sat5 THEN format('purchasable: unit cost %s vs parked pre-auth cap %s', v_cost, v_preauth_cap)
          ELSE 'no purchasing_cost on file for this pod, so no spot-buy candidate can be priced' END,
        'detail', jsonb_build_object('unit_cost', v_cost, 'preauth_cap', v_preauth_cap,
                                     'cap_is_parked_cs_param', true)),
      jsonb_build_object(
        'rung_no', 6, 'rung', 'blocked_demand', 'attempted', true,
        'satisfiable', true, 'qty_available', 0,
        'reason', CASE WHEN v_rung = 'blocked_demand'
                       THEN 'TERMINAL: every rung above exhausted, the full quantity is a real procurement gap'
                       ELSE format('not reached: resolved at rung %s (%s)', v_rung_no, v_rung) END,
        'detail', jsonb_build_object('qty_blocked', CASE WHEN v_rung = 'blocked_demand' THEN p_qty_needed ELSE 0 END,
                                     'writer', 'record_blocked_demand_v3 (stitch source lands with stitch_v3)')));

  ---------------------------------------------------------------------------
  -- LAW 5 / BUILD-SPEC line 88: silent qty-0 is a BUILD FAILURE. Assert it here rather
  -- than trusting callers: the ladder must always name a terminal rung, and a zero
  -- quantity is legal ONLY when that rung is blocked_demand.
  ---------------------------------------------------------------------------
  IF v_rung IS NULL THEN
    RAISE EXCEPTION 'resolve_supply_ladder_v3: no terminal rung resolved for machine %, shelf %, pod % - this is the silent qty-0 failure LAW 5 forbids',
      p_machine_id, p_shelf_id, p_pod_product_id;
  END IF;
  IF v_qty = 0 AND v_rung <> 'blocked_demand' THEN
    RAISE EXCEPTION 'resolve_supply_ladder_v3: rung % resolved with qty 0 without terminating at blocked_demand (machine %, shelf %, pod %) - silent qty-0 forbidden',
      v_rung, p_machine_id, p_shelf_id, p_pod_product_id;
  END IF;
  IF jsonb_array_length(v_ladder) <> 6 THEN
    RAISE EXCEPTION 'resolve_supply_ladder_v3: ladder logged % rungs, expected all 6 - every rung must be logged', jsonb_array_length(v_ladder);
  END IF;

  RETURN jsonb_build_object(
    'engine_tag',     'resolve_supply_ladder_v3',
    'plan_date',      p_plan_date,
    'machine_id',     p_machine_id,
    'machine_name',   v_machine_name,
    'shelf_id',       p_shelf_id,
    'pod_product_id', p_pod_product_id,
    'operating_model', v_op_model,
    'qty_needed',     p_qty_needed,
    'qty_resolved',   v_qty,
    'qty_shortfall',  GREATEST(p_qty_needed - v_qty, 0),
    'resolved_rung',  v_rung,
    'rung_no',        v_rung_no,
    'payload',        v_payload,
    'ladder',         v_ladder,
    'supply', jsonb_build_object(
        'gross_real_primary',       v_gross_primary,
        'gross_real_other',         v_gross_other,
        'sentinel_units_excluded',  v_sentinel,
        'claimed_units',            v_claimed,
        'net_primary',              v_net_primary,
        'net_other',                v_net_other,
        'variants_deduped',         v_variants,
        'wh_sourcing_allowed',      v_wh_allowed,
        'prefer_own_stock_transfer', v_prefer_own,
        'own_stock_transfer_preempted_substitution', v_own_full,
        'sentinel_classifier',      '_is_phantom_wh_row_v3',
        'allocation_model',         'claims consume primary WH first, then spill to other warehouses; phantom rows never counted as supply'),
    'assert_no_silent_qty0', true,
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END
$function$;



-- ---------------------------------------------------------------------------
-- READ-BACK, IN THIS TRANSACTION.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_src text; v_md5 text; v_acl text; v_n int;
BEGIN
  SELECT prosrc, md5(prosrc), COALESCE(array_to_string(proacl, ','), '(default)')
    INTO v_src, v_md5, v_acl
    FROM pg_proc WHERE proname = 'resolve_supply_ladder_v3'
     AND pronamespace = 'public'::regnamespace;

  IF v_md5 <> '011f83d81c46b8fc6a7b668bbc426b91' THEN
    RAISE EXCEPTION 'body md5 is %, expected 011f83d81c46b8fc6a7b668bbc426b91 - the fixture pins this exact value', v_md5;
  END IF;

  -- S-291(a): occurrence counts by substring arithmetic, never by regex. Measured against
  -- the live body before these numbers were written down, comment strings included.
  v_n := (length(v_src) - length(replace(v_src, '_is_phantom_wh_row_v3', ''))) / length('_is_phantom_wh_row_v3');
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'canonical predicate appears % time(s), expected 5 (3 filters + 1 reason string + 1 supply key)', v_n;
  END IF;
  IF position('VOXSOURCE-%''' IN v_src) > 0 THEN
    RAISE EXCEPTION 'S-293: an inline name-only sentinel test survives in the ladder body';
  END IF;

  -- The rung LOG must still carry all six rungs: only the TERMINAL choice was allowed to
  -- move. ⛔ The count is SEVEN, not six, and it was MEASURED rather than reasoned about
  -- (S-291b): six log entries plus the terminal rung's own key in the returned object.
  -- A first guess of 6 here would have refused a correct migration.
  v_n := (length(v_src) - length(replace(v_src, '''rung_no'', ', ''))) / length('''rung_no'', ');
  IF v_n <> 7 THEN
    RAISE EXCEPTION 'the ladder carries % rung_no key(s), expected 7 (six logged rungs + the terminal key)', v_n;
  END IF;

  -- S-140: read the ACL back WHOLE. CREATE OR REPLACE preserves grants, so this is a check
  -- that nothing was silently widened, not a change.
  IF v_acl <> 'postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres' THEN
    RAISE EXCEPTION 'ladder ACL is % - anon/PUBLIC must never appear here (S-57, S-268)', v_acl;
  END IF;

  IF (SELECT provolatile FROM pg_proc WHERE proname = 'resolve_supply_ladder_v3'
        AND pronamespace = 'public'::regnamespace) <> 's'
     OR (SELECT prosecdef FROM pg_proc WHERE proname = 'resolve_supply_ladder_v3'
           AND pronamespace = 'public'::regnamespace) THEN
    RAISE EXCEPTION 'the ladder must stay STABLE and SECURITY INVOKER (LAW 4 / S-104)';
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- BEHAVIOURAL READ-BACK on the fixture's own anchor: the ruling actually fired.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  v := public.resolve_supply_ladder_v3(DATE '2030-01-07',
         '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'::uuid,
         '7a2c7e07-271a-4f01-aa21-b9929c7bd1bd'::uuid,
         '4901aaf4-a2f4-4d62-a089-d68178aa6c7f'::uuid, 6, 5);
  IF v->>'resolved_rung' <> 'alt_wh' THEN
    RAISE EXCEPTION 'D-37 did not fire on the anchor: terminal rung is %', v->>'resolved_rung';
  END IF;
  IF (v->'supply'->>'own_stock_transfer_preempted_substitution') <> 'true' THEN
    RAISE EXCEPTION 'the ladder did not self-report the D-37 preemption';
  END IF;
  IF jsonb_array_length(v->'ladder') <> 6 THEN
    RAISE EXCEPTION 'the ladder log lost a rung: %', jsonb_array_length(v->'ladder');
  END IF;
END $do$;

SELECT 'prd110_leg155_d37_ladder_own_stock_transfer_and_s293' AS applied;
