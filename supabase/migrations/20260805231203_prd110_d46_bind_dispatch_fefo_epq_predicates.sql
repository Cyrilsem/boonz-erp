-- PRD-110 · D-46 EXECUTE — bind_dispatch_fefo: restore the two safety predicates inside the
-- UPDATE's OWN WHERE clause (S-237 / S-239 / S-240).
--
-- WHY. Under READ COMMITTED, when an UPDATE meets a row that a concurrent transaction has just
-- committed, Postgres runs an EvalPlanQual recheck against the NEW row version and re-evaluates
-- ONLY the UPDATE's own quals. Predicates consumed while building the `targets` CTE are never
-- re-applied. So a dispatch line that turns packed=true — or gets bound by a second binder —
-- between the bind statement's snapshot and its row lock is STILL re-bound.
--
-- MEASURED, NOT REASONED. scripts/prd110_s5_epq_rebind_probe.sh (leg 123) reproduced this on a
-- scratch table in this function's exact CTE shape: bind blocked 3.0 s on the pack side's row
-- lock, and the final state was packed=true with the binder's value written anyway.
--
-- WHY IT IS A MONEY DEFECT, NOT A CURIOSITY. create_spot_purchase_v3 calls this binder at step 6
-- with a machine scope. A spot buy landing while the warehouse packs that same machine silently
-- re-points an already-packed line at a batch it was never picked from. pack_dispatch_line
-- debited batch X and stamped X's expiry; the row then says Y. The damage surfaces later, in the
-- credit paths — return_dispatch_line and credit_dispatch_remainder credit back to
-- from_wh_inventory_id, i.e. to Y with Y's expiry. Stock is destroyed on X and minted on Y:
-- a conservation break and a FEFO poisoning in one. The second, simpler case falls out of the
-- same gap — two concurrent binds for one machine each overwrite the other's binding, which is
-- the literal "a dispatch line binds twice" that S5 exists to refute.
--
-- CHANGE. Exactly two additive predicates in the UPDATE's WHERE. Nothing else in the body moves:
-- same signature, same return shape, same role gate, same GUCs, same targets/picks CTEs.
-- Article 12: forward-only CREATE OR REPLACE, no DROP, no edit of a past migration.
-- Article 1: bind_dispatch_fefo remains the single canonical binder — no new write path.
-- Article 4: role gate, app.via_rpc / app.rpc_name / app.mutation_reason all unchanged.
--
-- ⛔ pack_dispatch_line is CLEAN and is NOT touched: it takes FOR UPDATE on the dispatch row
--    before testing `packed` and debits with a relative delta under FOR UPDATE on the batch.

CREATE OR REPLACE FUNCTION public.bind_dispatch_fefo(p_plan_date date, p_machine_names text[] DEFAULT NULL::text[], p_caller_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_bound   int;
  v_left    int;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'bind_dispatch_fefo: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','bind_dispatch_fefo', true);
  PERFORM set_config('app.via_trigger','true', true);
  PERFORM set_config('app.mutation_reason', format('FEFO bind plan_date=%s by=%s', p_plan_date, v_user_id), true);

  WITH targets AS (
    SELECT rd.dispatch_id, rd.boonz_product_id, rd.machine_id,
           COALESCE(rd.from_warehouse_id, public.wh_central_id()::uuid) AS wh
    FROM public.refill_dispatching rd
    WHERE rd.dispatch_date = p_plan_date
      AND rd.action IN ('Refill','Add','Add New')
      AND rd.from_wh_inventory_id IS NULL
      AND COALESCE(rd.item_added,false) = false
      AND COALESCE(rd.returned,false)   = false
      AND COALESCE(rd.cancelled,false)  = false
      AND COALESCE(rd.packed,false)     = false
      AND COALESCE(rd.is_m2m,false)     = false
      AND (p_machine_names IS NULL
           OR rd.machine_id IN (SELECT machine_id FROM public.machines WHERE official_name = ANY(p_machine_names)))
  ),
  picks AS (
    SELECT t.dispatch_id, t.wh AS warehouse_id,
      ( SELECT p.wh_inventory_id
        FROM public.v_wh_pickable p
        WHERE p.boonz_product_id = t.boonz_product_id
          AND p.warehouse_id = t.wh
          AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = t.machine_id)
          AND COALESCE(p.warehouse_stock,0) > 0
        ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
        LIMIT 1 ) AS wh_inventory_id
    FROM targets t
  ),
  upd AS (
    UPDATE public.refill_dispatching rd
       SET from_wh_inventory_id = picks.wh_inventory_id,
           from_warehouse_id    = COALESCE(rd.from_warehouse_id, picks.warehouse_id)
    FROM picks
    WHERE rd.dispatch_id = picks.dispatch_id
      AND picks.wh_inventory_id IS NOT NULL
      -- ⛔ D-46 / S-237: these two are RE-STATED here on purpose. They already exist in `targets`,
      -- but a CTE predicate is NOT re-applied by the EvalPlanQual recheck when a concurrent
      -- transaction commits between this statement's snapshot and its row lock. Only the quals
      -- written HERE survive that recheck. Do not "de-duplicate" them back out.
      AND COALESCE(rd.packed,false) = false
      AND rd.from_wh_inventory_id IS NULL
    RETURNING 1
  )
  SELECT count(*) INTO v_bound FROM upd;

  SELECT count(*) INTO v_left
  FROM public.refill_dispatching rd
  WHERE rd.dispatch_date = p_plan_date
    AND rd.action IN ('Refill','Add','Add New')
    AND rd.from_wh_inventory_id IS NULL
    AND COALESCE(rd.item_added,false)=false AND COALESCE(rd.returned,false)=false
    AND COALESCE(rd.cancelled,false)=false AND COALESCE(rd.packed,false)=false AND COALESCE(rd.is_m2m,false)=false
    AND (p_machine_names IS NULL
         OR rd.machine_id IN (SELECT machine_id FROM public.machines WHERE official_name = ANY(p_machine_names)));

  RETURN jsonb_build_object('status','ok','plan_date',p_plan_date,'bound',v_bound,
                            'still_unbound_no_wh_stock',v_left);
END;
$function$;
