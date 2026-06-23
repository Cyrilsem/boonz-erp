-- PRD-053 PHASE A — stitch conservation (NO LEAKAGE).
--
-- ROOT CAUSE (VML-1004-0500-O1 A03 Ice Tea, 2026-06-23): pod_refill_plan REMOVE
-- qty = 13 (correct, = live WEIMI shelf). stitch_pod_to_boonz sized the boonz
-- REMOVE child from pod_inventory current_stock via
--   ... ELSE LEAST( (FEFO distribution), current_stock )::int ...
-- so 13 -> LEAST(13, 6 Active) = 6, and 7 leaked. The conservation PARENT must be
-- the pod_refill_plan qty (the original instruction), never a qty re-derived from
-- pod_inventory.
--
-- THIS MIGRATION (files only; apply nothing yet):
--   1. stitch_leakage     — telemetry table (instruction + delta), append-only.
--   2. check_pod_conservation(date) — read-only checker: per REMOVE/M2W
--      instruction, parent pod qty vs SUM(dispatch children); rows where they differ.
--   3. stitch_pod_to_boonz — surgical: DROP the `LEAST(..., current_stock)` cap on
--      the REMOVE child (size from the pod plan total). engine v26 -> v27. Done via
--      a DO-block over the LIVE body (pg_get_functiondef) so we never guess; a guard
--      RAISEs if the target substring is not found or the cap survives.
--   4. push_plan_to_dispatch(date,text) — a DURABLE, pre-write conservation GATE runs
--      first: for every REMOVE/M2W instruction the approved plan must sum to the pod
--      plan; on any mismatch it writes a stitch_leakage row and RETURNS an error
--      WITHOUT writing any dispatch (stop-ship). No RAISE, so the telemetry COMMITS and
--      survives the blocked publish (dblink/pg_background autonomous tx rejected: dblink
--      loopback on Supabase needs a hardcoded DB password = unsafe; pg_background not
--      installed). Then REMOVE/M2W children are split across the shelf's known Active
--      pod_inventory batches by FEFO; any remainder not attributable to a known batch
--      is written as ONE line with expiry_date = NULL (expiry-to-confirm) so the
--      children always sum to the pod plan.
--
-- Protected entities touched only through their canonical writers; forward-only; no
-- _v2; no deletes; no qty cut. Cody verdict accompanies this file. swaps_enabled
-- untouched.

-- ── 1. telemetry ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.stitch_leakage (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date       date NOT NULL,
  machine_id      uuid,
  shelf_id        uuid,
  pod_product_id  uuid,
  action          text NOT NULL,
  parent_pod_qty  int  NOT NULL,
  children_sum    int  NOT NULL,
  delta           int  NOT NULL,          -- parent_pod_qty - children_sum
  detected_by     text NOT NULL,
  detected_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.stitch_leakage ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stitch_leakage_select ON public.stitch_leakage;
CREATE POLICY stitch_leakage_select ON public.stitch_leakage
  FOR SELECT USING (EXISTS (SELECT 1 FROM public.user_profiles up
                            WHERE up.id = (SELECT auth.uid())
                              AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])));
-- append-only: no UPDATE/DELETE policy (writes only via DEFINER writers, which bypass RLS as owner).
GRANT SELECT ON public.stitch_leakage TO authenticated, service_role;
COMMENT ON TABLE public.stitch_leakage IS
  'PRD-053: stitch/push conservation telemetry. One row per non-conserving (REMOVE/M2W) instruction at publish time. delta = parent_pod_qty - children_sum.';

-- ── 2. read-only conservation checker ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.check_pod_conservation(p_plan_date date)
RETURNS TABLE(
  machine_id uuid, shelf_id uuid, pod_product_id uuid, action text,
  parent_pod_qty int, children_sum int, delta int
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
  SELECT prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action,
         prp.qty::int AS parent_pod_qty,
         COALESCE(SUM(rd.quantity), 0)::int AS children_sum,
         (prp.qty - COALESCE(SUM(rd.quantity), 0))::int AS delta
  FROM public.pod_refill_plan prp
  LEFT JOIN public.refill_dispatching rd
    ON rd.machine_id     = prp.machine_id
   AND rd.shelf_id       = prp.shelf_id
   AND rd.pod_product_id = prp.pod_product_id
   AND rd.dispatch_date  = prp.plan_date
   AND rd.action IN ('Remove','Machine To Warehouse')
   AND COALESCE(rd.cancelled, false) = false
  WHERE prp.plan_date = p_plan_date
    AND prp.action IN ('REMOVE','M2W')
    AND prp.qty > 0
  GROUP BY prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action, prp.qty
  HAVING prp.qty <> COALESCE(SUM(rd.quantity), 0);
$function$;
GRANT EXECUTE ON FUNCTION public.check_pod_conservation(date) TO authenticated, service_role;
COMMENT ON FUNCTION public.check_pod_conservation(date) IS
  'PRD-053: read-only. REMOVE/M2W instructions whose dispatch children do not sum to the pod plan qty (the conservation parent). Empty result = conserving.';

-- ── 3. stitch_pod_to_boonz: drop the pod_inventory cap on the REMOVE child ───
DO $do$
DECLARE
  v_def  text;
  v_old  text;
  v_new  text;
BEGIN
  v_def := pg_get_functiondef('public.stitch_pod_to_boonz(date,boolean)'::regprocedure);

  -- the LIVE REMOVE-child CASE (remove_lines CTE): internal_transfer keeps the FEFO
  -- distribution; warehouse caps it to current_stock with LEAST(...). PRD-053: both
  -- branches must size from the pod plan total (no cap), so SUM(children)=pod qty.
  v_old :=
'           CASE WHEN source_origin = ''internal_transfer''
             THEN (FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int
                   + CASE WHEN variant_rank <=
                          (pod_qty - FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int * variant_count)
                          THEN 1 ELSE 0 END)::int
             ELSE LEAST(
                   (FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int
                    + CASE WHEN variant_rank <=
                           (pod_qty - FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int * variant_count)
                           THEN 1 ELSE 0 END)::int,
                   current_stock)::int
           END AS variant_final,';

  v_new :=
'           -- PRD-053: size REMOVE from the pod plan total; do NOT cap to pod_inventory.
           (FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int
            + CASE WHEN variant_rank <=
                   (pod_qty - FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int * variant_count)
                   THEN 1 ELSE 0 END)::int AS variant_final,';

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'PRD-053 stitch patch: target REMOVE-cap block not found in live body (drifted). Re-fetch and re-author.';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position('ELSE LEAST(' IN v_def) > 0 THEN
    RAISE EXCEPTION 'PRD-053 stitch patch: LEAST cap still present after replace.';
  END IF;
  v_def := replace(v_def, '''engine_version'',''v26_multivariant_spread''',
                          '''engine_version'',''v27_remove_conservation''');
  EXECUTE v_def;
END
$do$;

-- ── 4. push_plan_to_dispatch: FEFO batch split + NULL remainder + assert ─────
CREATE OR REPLACE FUNCTION public.push_plan_to_dispatch(p_plan_date date, p_machine_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id              uuid;
  v_machine_id           uuid;
  v_primary_warehouse_id uuid;
  v_count                int := 0;
  v_skipped              int := 0;
  v_pinned_count         int := 0;
  v_procurement_gaps     int := 0;
  v_preserved            int := 0;
  v_remove_split         int := 0;
  v_leak_n               int := 0;
  line                   RECORD;
  v_batch                RECORD;
  v_leak                 RECORD;
  v_remaining            int;
  v_take                 int;
  v_shelf_id             uuid;
  v_pod_product_id       uuid;
  v_boonz_product_id     uuid;
  v_normalized_shelf     text;
  v_action               text;
  v_dispatch_comment     text;
  v_new_dispatch_id      uuid;
  v_existing_edit_id     uuid;
  v_pinned_wh_id         uuid;
  v_pinned_expiry        date;
  v_pin_eligible         boolean;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'push_plan_to_dispatch: caller % lacks required role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RETURN jsonb_build_object('status','error','error','p_plan_date is required'); END IF;
  IF p_machine_name IS NULL OR length(trim(p_machine_name)) = 0 THEN
    RETURN jsonb_build_object('status','error','error','p_machine_name is required');
  END IF;

  SELECT machine_id, primary_warehouse_id INTO v_machine_id, v_primary_warehouse_id
    FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: '||p_machine_name);
  END IF;

  -- ── PRD-053: conservation GATE (pre-write, DURABLE, stop-ship). ──
  -- For every REMOVE/M2W instruction, the approved plan (refill_plan_output — what we
  -- are about to dispatch) MUST sum to the pod_refill_plan qty. On any mismatch we
  -- record durable telemetry to stitch_leakage and RETURN an error WITHOUT writing any
  -- dispatch row (stop-ship). No RAISE -> the telemetry row COMMITS and survives even
  -- though nothing ships. (A dblink / pg_background autonomous transaction was rejected:
  -- dblink loopback on Supabase requires a hardcoded DB password = unsafe credential
  -- handling, and pg_background is not installed; this pre-write gate is durable by
  -- construction and refuses to ship identically.)
  v_leak_n := 0;
  FOR v_leak IN
    SELECT prp.shelf_id, prp.pod_product_id, prp.action,
           prp.qty::int AS parent, COALESCE(g.children,0)::int AS children
    FROM pod_refill_plan prp
    LEFT JOIN (
      SELECT sc.shelf_id, pp.pod_product_id,
             CASE upper(trim(rpo.action))
               WHEN 'REMOVE' THEN 'REMOVE' WHEN 'MACHINE TO WAREHOUSE' THEN 'M2W' END AS pod_action,
             SUM(rpo.quantity)::int AS children
      FROM refill_plan_output rpo
      JOIN shelf_configurations sc ON sc.machine_id = v_machine_id
           AND sc.shelf_code = regexp_replace(rpo.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2')
      JOIN pod_products pp ON lower(trim(pp.pod_product_name)) = lower(trim(rpo.pod_product_name))
      WHERE rpo.plan_date = p_plan_date AND rpo.machine_name = p_machine_name
        AND rpo.operator_status = 'approved' AND rpo.dispatched = false
        AND upper(trim(rpo.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
      GROUP BY sc.shelf_id, pp.pod_product_id, 3
    ) g ON g.shelf_id = prp.shelf_id AND g.pod_product_id = prp.pod_product_id AND g.pod_action = prp.action
    WHERE prp.plan_date = p_plan_date AND prp.machine_id = v_machine_id
      AND prp.action IN ('REMOVE','M2W') AND prp.qty > 0
      AND prp.qty <> COALESCE(g.children, 0)
  LOOP
    INSERT INTO public.stitch_leakage(plan_date, machine_id, shelf_id, pod_product_id,
                                      action, parent_pod_qty, children_sum, delta, detected_by)
    VALUES (p_plan_date, v_machine_id, v_leak.shelf_id, v_leak.pod_product_id,
            v_leak.action, v_leak.parent, v_leak.children, v_leak.parent - v_leak.children,
            'push_plan_to_dispatch');
    v_leak_n := v_leak_n + 1;
  END LOOP;
  IF v_leak_n > 0 THEN
    RETURN jsonb_build_object(
      'status','conservation_violation',
      'machine', p_machine_name,
      'leaking_instructions', v_leak_n,
      'reason','SUM(approved plan children) <> pod_refill_plan qty for REMOVE/M2W — stop-ship; logged durably to stitch_leakage (PRD-053)'
    );
  END IF;

  FOR line IN
    SELECT * FROM refill_plan_output
    WHERE plan_date = p_plan_date AND machine_name = p_machine_name
      AND operator_status = 'approved' AND dispatched = false
  LOOP
    v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
    SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id=v_machine_id AND shelf_code=v_normalized_shelf;
    SELECT pod_product_id INTO v_pod_product_id FROM pod_products WHERE lower(trim(pod_product_name))=lower(trim(line.pod_product_name)) LIMIT 1;
    SELECT product_id INTO v_boonz_product_id FROM boonz_products WHERE lower(trim(boonz_product_name))=lower(trim(line.boonz_product_name)) LIMIT 1;

    IF v_boonz_product_id IS NULL OR v_pod_product_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT rd.dispatch_id INTO v_existing_edit_id
      FROM refill_dispatching rd
     WHERE rd.machine_id     = v_machine_id
       AND rd.dispatch_date  = line.plan_date
       AND rd.shelf_id       = v_shelf_id
       AND rd.pod_product_id = v_pod_product_id
       AND (rd.created_by_edit OR rd.edit_count > 0 OR rd.cancelled OR rd.skipped)
     ORDER BY rd.created_at DESC NULLS LAST
     LIMIT 1;
    IF v_existing_edit_id IS NOT NULL THEN
      UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_edit_id WHERE id = line.id;
      v_preserved := v_preserved + 1;
      CONTINUE;
    END IF;

    v_action := CASE upper(trim(line.action))
      WHEN 'REFILL' THEN 'Refill' WHEN 'ADD NEW' THEN 'Add New'
      WHEN 'REMOVE' THEN 'Remove' WHEN 'MACHINE TO WAREHOUSE' THEN 'Machine To Warehouse'
      WHEN 'SWAP' THEN 'Add New' ELSE trim(line.action)
    END;

    v_dispatch_comment := CASE
      WHEN line.operator_comment IS NOT NULL AND trim(line.operator_comment) != '' THEN
        COALESCE(NULLIF(trim(line.comment), '') || E'\n', '') || E'\U0001F4AC ' || trim(line.operator_comment)
      ELSE line.comment
    END;

    -- ── PRD-053: REMOVE / M2W are CONSERVED, never capped to pod_inventory. ──
    -- Split the pod-plan qty across the shelf's known Active pod_inventory batches
    -- (FEFO); whatever cannot be attributed to a known batch is written as ONE more
    -- line with expiry_date = NULL (expiry-to-confirm) so the children sum to the plan.
    IF v_action IN ('Remove','Machine To Warehouse') THEN
      v_remaining := line.quantity;
      v_new_dispatch_id := NULL;
      FOR v_batch IN
        SELECT pil.expiration_date, pil.current_stock
          FROM public.v_pod_inventory_latest pil
         WHERE pil.machine_id = v_machine_id
           AND pil.shelf_id   = v_shelf_id
           AND pil.boonz_product_id = v_boonz_product_id
           AND pil.status = 'Active'
           AND COALESCE(pil.current_stock,0) > 0
         ORDER BY pil.expiration_date ASC NULLS LAST
      LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(v_batch.current_stock, v_remaining);
        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, v_take, true, v_dispatch_comment,
          v_primary_warehouse_id, NULL, v_batch.expiration_date, false,
          COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
          CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
          false, false, false, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;
        v_remaining := v_remaining - v_take;
        v_count := v_count + 1; v_remove_split := v_remove_split + 1;
      END LOOP;
      IF v_remaining > 0 THEN
        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, v_remaining, true,
          COALESCE(NULLIF(v_dispatch_comment,'') || E'\n', '') || '[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]',
          v_primary_warehouse_id, NULL, NULL, false,
          COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
          CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
          false, false, false, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;
        v_count := v_count + 1; v_remove_split := v_remove_split + 1;
      END IF;
      UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
      CONTINUE;
    END IF;

    -- ── Refill / Add New: existing FEFO warehouse-source pin (unchanged) ──
    v_pin_eligible := (v_action IN ('Refill','Add New'))
                      AND (COALESCE(line.source_origin::text, 'warehouse') = 'warehouse');
    v_pinned_wh_id := NULL;
    v_pinned_expiry := NULL;

    IF v_pin_eligible AND v_primary_warehouse_id IS NOT NULL THEN
      SELECT wh_inventory_id, expiration_date
        INTO v_pinned_wh_id, v_pinned_expiry
      FROM warehouse_inventory
       WHERE warehouse_id = v_primary_warehouse_id
         AND boonz_product_id = v_boonz_product_id
         AND status = 'Active'
         AND coalesce(warehouse_stock, 0) > 0
       ORDER BY expiration_date ASC NULLS LAST, wh_inventory_id ASC
       LIMIT 1;

      IF v_pinned_wh_id IS NULL THEN
        v_procurement_gaps := v_procurement_gaps + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES (
          'procurement_gap', 'warning',
          jsonb_build_object(
            'title', format('Procurement gap: %s at %s', line.boonz_product_name, p_machine_name),
            'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
            'boonz_product_id', v_boonz_product_id, 'boonz_product_name', line.boonz_product_name,
            'wh_id', v_primary_warehouse_id, 'action', v_action, 'qty_needed', line.quantity,
            'detected_by', 'push_plan_to_dispatch_FEFO_pin', 'detected_at', now()
          )
        );
      ELSE
        v_pinned_count := v_pinned_count + 1;
      END IF;
    END IF;

    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
      source_origin, from_machine_id,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES (
      v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
      line.plan_date, v_action, line.quantity, true, v_dispatch_comment,
      v_primary_warehouse_id, v_pinned_wh_id, v_pinned_expiry, v_pin_eligible,
      COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
      CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
      false, false, false, false, false
    ) RETURNING dispatch_id INTO v_new_dispatch_id;

    UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
    v_count := v_count + 1;
  END LOOP;

  -- Post-write sanity: the conservation gate above already refused to ship any
  -- non-conserving plan, and the REMOVE/M2W split is exact by construction, so the
  -- dispatch children now equal the pod plan. check_pod_conservation(p_plan_date) is
  -- the read-only monitor for post-hoc scans / cron.

  RETURN jsonb_build_object(
    'status','ok',
    'machine', p_machine_name,
    'lines_pushed', v_count,
    'lines_skipped_null_product', v_skipped,
    'lines_preserved_manual_edit', v_preserved,
    'lines_pinned_at_plan_time', v_pinned_count,
    'remove_split_lines', v_remove_split,
    'procurement_gaps_logged', v_procurement_gaps,
    'rpc_version','v6_prd053_conservation'
  );
END $function$;
