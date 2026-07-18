-- ============================================================================
-- 20260718090002_rc01_single_writer_bridge.sql
-- RC-01 — single-writer plan->dispatch bridge (Design A: push is the sole writer).
--
-- >>> APPLY OFF-PEAK ONLY <<<  (B4)
--   NEVER during the 8pm Asia/Dubai refill-brain engine run, and NEVER during a
--   field packing window. The partial unique index below is created NON-CONCURRENT
--   inline (tiny table, verified 0 collisions) — it takes a brief ACCESS EXCLUSIVE
--   lock on refill_dispatching. Off-peak makes that lock a non-event.
--
--   *** MANDATORY PRE-CHECK (B4) — run this FIRST; abort the whole apply if it
--       returns anything other than colliding_groups=0, max_multiplicity=0: ***
--
--     SELECT count(*) AS colliding_groups, COALESCE(max(c),0) AS max_multiplicity
--     FROM (
--       SELECT dispatch_date, machine_id, shelf_id, boonz_product_id, action, count(*) c
--       FROM public.refill_dispatching
--       WHERE include=true AND action IN ('Refill','Add New')
--         AND COALESCE(filled_quantity,0)=0
--         AND packed=false AND item_added=false AND returned=false
--         AND skipped=false AND cancelled=false AND created_by_edit=false AND is_m2m=false
--       GROUP BY 1,2,3,4,5 HAVING count(*)>1
--     ) g;
--   Last verified 2026-07-18: colliding_groups=0, max_multiplicity=0.
--
-- Closes Cody conditions:
--   B1  push binds the ONE canonical availability interface public.wh_fefo_for_line
--       (netted, wh-param, RC-01-shaped return). Cold lines route to WH_CENTRAL.
--   B3  approve_refill_plan is owned HERE (RC-01). Its rewrite DROPS Step-3, which
--       carried one of the 9 WH_CENTRAL literals -> only 8 literal sites remain for
--       RC-08 Migration B. approve is NOT touched by RC-08-B.
--   B4  partial unique index, IF NOT EXISTS, non-concurrent inline, off-peak header + pre-check.
--   B5  ATOMIC with RC-08 Migration A (which defines wh_fefo_for_line): A applies first,
--       in the SAME window. push's pin does NOT switch off inline logic until the
--       function exists. See APPLY_ORDER.md.
-- CS decisions:
--   S2  The FE-direct push caller (RefillPlanReview.tsx:226) and repack_machine's push
--       call are KEPT. push is idempotent (partial index belt + preserve suspenders),
--       so multiple entrypoints are safe. No caller removal. (FE payload-dependency
--       check for RefillPlanReview is a Stax/FE task, noted in RECONCILIATION.md.)
--
-- Protected entities: refill_dispatching, refill_plan_output. Article 1 allowlist
-- already contains approve_refill_plan + push_plan_to_dispatch (no allowlist change).
-- Live bodies pulled 2026-07-18 via pg_get_functiondef; UNCHANGED logic reproduced
-- byte-faithful, minimal diffs marked "RC-01".
-- ============================================================================
BEGIN;

-- ── (I) IDEMPOTENCY: partial unique index (the hard guarantee) ───────────────
-- Scope = exactly "one unstarted warehouse Refill/Add New instruction" on the
-- natural key. FEFO Remove/M2W splits, M2M legs, edit rows, driver slices are all
-- EXCLUDED by the predicate. Non-concurrent (see off-peak header); IF NOT EXISTS.
CREATE UNIQUE INDEX IF NOT EXISTS uq_dispatch_unstarted_wh_refill
  ON public.refill_dispatching
     (dispatch_date, machine_id, shelf_id, boonz_product_id, action)
  WHERE include = true
    AND action IN ('Refill','Add New')
    AND COALESCE(filled_quantity, 0) = 0
    AND packed        = false
    AND item_added    = false
    AND returned      = false
    AND skipped       = false
    AND cancelled     = false
    AND created_by_edit = false
    AND is_m2m        = false;

-- ── (II) approve_refill_plan: Step-1 flip ONLY. Drop Step-2 DELETE + Step-3 ───
-- re-insert (push is authoritative). Re-stamp app.rpc_name after the nested
-- trigger->push (Article 8). NO DELETE remains in the bridge. NO WH_CENTRAL literal.
CREATE OR REPLACE FUNCTION public.approve_refill_plan(p_plan_date date, p_machine_names text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role    text;
  v_rows_approved  int := 0;
  v_dispatch_rows  int := 0;
  v_slot_guard     jsonb := NULL;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  SELECT role INTO v_caller_role
  FROM user_profiles WHERE id = auth.uid();

  IF v_caller_role NOT IN ('operator_admin', 'superadmin', 'manager') THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error', 'Insufficient role — approval requires operator_admin, superadmin, or manager'
    );
  END IF;

  IF p_plan_date IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_plan_date is required');
  END IF;
  IF p_machine_names IS NULL OR array_length(p_machine_names, 1) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_machine_names must be a non-empty array');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM refill_plan_output
    WHERE plan_date = p_plan_date
      AND machine_name = ANY(p_machine_names)
      AND operator_status = 'pending'
  ) THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error', 'No pending rows found for the specified date and machines'
    );
  END IF;

  -- drift-kill P1: WEIMI slot guard runs on every approve (warn logs; block
  -- rejects mismatched pending lines so they never reach dispatching).
  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, NULL);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  -- Step 1: flip to approved. Fires trg_refill_plan_output_approve_to_dispatch ->
  -- trg_fire_dispatch_on_approval -> push_plan_to_dispatch (THE SOLE WRITER).
  UPDATE refill_plan_output
  SET operator_status = 'approved',
      reviewed_at     = now()
  WHERE plan_date        = p_plan_date
    AND machine_name     = ANY(p_machine_names)
    AND operator_status  = 'pending';

  GET DIAGNOSTICS v_rows_approved = ROW_COUNT;

  -- RC-01 §6 (Article 8): the nested push overwrote app.rpc_name := 'push_plan_to_dispatch'.
  -- Re-stamp so any further audit in approve is attributed to approve (mirrors the
  -- reset_approved_undispatched pattern). Under Design A there are no further writes
  -- here, but this fixes the current mis-attribution and is future-proof.
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'approve_refill_plan', true);

  -- RC-01: Step-2 (unguarded DELETE that destroyed the trigger's rich pins/M2M/Remove
  -- splits) and Step-3 (bare 10-col legacy re-insert incl. the WH_CENTRAL literal) are
  -- REMOVED. push is authoritative. Report the rows push materialised in this txn:
  SELECT count(*) INTO v_dispatch_rows
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date = p_plan_date
    AND m.official_name = ANY(p_machine_names)
    AND rd.include = true
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false;

  RETURN jsonb_build_object(
    'status',                   'ok',
    'plan_date',                p_plan_date,
    'rows_approved',            v_rows_approved,
    'dispatching_rows_present', v_dispatch_rows,
    -- RC-01 backward-compat: FE RefillPlanningTab.tsx:1090 reads the legacy key
    -- `dispatching_rows_written` for its approval toast. Under Design A the trigger
    -- (not approve) writes the rows, but we report the same count under the old key
    -- so the FE needs no coordinated redeploy. Safe to retire once FE reads the new key.
    'dispatching_rows_written', v_dispatch_rows,
    'weimi_slot_guard',         v_slot_guard,
    'machines',                 p_machine_names,
    'writer',                   'push_plan_to_dispatch'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE
  );
END;
$function$;

-- ── (III) push_plan_to_dispatch: fixed preserve (§5) + cold-route + ──────────
-- wh_fefo_for_line pin (§7 / B1) + ON CONFLICT upsert on the partial index (§3b).
-- Full v9 body reproduced byte-faithful; only the four RC-01 edits differ (marked).
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
  -- RC-01 additions: per-line route WH (cold->central) + pinned batch route WH
  v_storage_temp         text;
  v_line_wh_id           uuid;
  v_pinned_route_wh      uuid;
  -- PRD-071 WS-B additions
  v_pairing              jsonb := NULL;
  v_prev_via_trigger     text;
  v_prev_mutation_reason text;
  v_transfer_id          uuid;
  v_src_line             RECORD;
  v_src_machine_id       uuid;
  v_src_shelf_id         uuid;
  v_src_normalized_shelf text;
  v_first_remove_id      uuid;
  v_dest_leg_id          uuid;
  v_earliest_expiry      date;
  v_transfer_pairs       int := 0;
  v_transfer_deferred    int := 0;
  v_transfer_skipped     int := 0;
  v_slot_guard           jsonb := NULL;
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

  -- drift-kill P1: WEIMI slot guard (block rejects mismatched plan lines here,
  -- before they bridge to dispatching; warn logs to monitoring_alerts)
  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, p_machine_name);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

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
    -- PRD-CLEAN-05 v9: prefer the ID columns written by write_refill_plan g8;
    -- fall back to name matching for historical rows where they are NULL.
    v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
    v_shelf_id := line.shelf_id;
    IF v_shelf_id IS NULL THEN
      SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id=v_machine_id AND shelf_code=v_normalized_shelf;
    END IF;
    v_pod_product_id := line.pod_product_id;
    IF v_pod_product_id IS NULL THEN
      SELECT pod_product_id INTO v_pod_product_id FROM pod_products WHERE lower(trim(pod_product_name))=lower(trim(line.pod_product_name)) LIMIT 1;
    END IF;
    v_boonz_product_id := line.boonz_product_id;
    IF v_boonz_product_id IS NULL THEN
      SELECT product_id INTO v_boonz_product_id FROM boonz_products WHERE lower(trim(boonz_product_name))=lower(trim(line.boonz_product_name)) LIMIT 1;
    END IF;

    IF v_boonz_product_id IS NULL OR v_pod_product_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    -- RC-01 §5(5a): preserve a LIVE manual-edit row (edit rows only; dead skipped/
    -- cancelled rows NO LONGER preserve -> reset->re-approve mints fresh).
    SELECT rd.dispatch_id INTO v_existing_edit_id
      FROM refill_dispatching rd
     WHERE rd.machine_id     = v_machine_id
       AND rd.dispatch_date  = line.plan_date
       AND rd.shelf_id       = v_shelf_id
       AND rd.pod_product_id = v_pod_product_id
       AND (rd.created_by_edit OR rd.edit_count > 0)
       AND COALESCE(rd.skipped,   false) = false
       AND COALESCE(rd.cancelled, false) = false
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

    -- RC-01 §5(5b): multi-wave idempotency for warehouse Refill/Add New — adopt an
    -- existing LIVE dispatch on the natural key (incl. packed/started) instead of
    -- minting a gen-2 twin. skipped/cancelled/is_m2m excluded so reset->re-approve
    -- still mints fresh. (Belt = partial index; this is the primary suspenders +
    -- the packed-twin case the index by design does not cover.)
    IF v_action IN ('Refill','Add New')
       AND COALESCE(line.source_origin::text, 'warehouse') = 'warehouse' THEN
      SELECT rd.dispatch_id INTO v_existing_edit_id
        FROM refill_dispatching rd
       WHERE rd.machine_id       = v_machine_id
         AND rd.dispatch_date    = line.plan_date
         AND rd.shelf_id         = v_shelf_id
         AND rd.boonz_product_id = v_boonz_product_id
         AND rd.action           = v_action
         AND rd.include          = true
         AND COALESCE(rd.skipped,   false) = false
         AND COALESCE(rd.cancelled, false) = false
         AND COALESCE(rd.is_m2m,    false) = false
       ORDER BY rd.created_at DESC NULLS LAST
       LIMIT 1;
      IF v_existing_edit_id IS NOT NULL THEN
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_edit_id WHERE id = line.id;
        v_preserved := v_preserved + 1;
        CONTINUE;
      END IF;
    END IF;

    -- PRD-071 WS-B: internal_transfer lines become pre-paired M2M writes.
    -- block_orphan_internal_transfer (PRD-070) forbids unpaired legs, so the
    -- dest line (carries from_machine_id) creates BOTH legs atomically with a
    -- shared m2m_transfer_id; the source Remove line defers to the dest push.
    -- Per-line failures log to monitoring_alerts and never fail the push.
    IF COALESCE(line.source_origin::text,'warehouse') = 'internal_transfer' THEN
      IF v_action IN ('Remove','Machine To Warehouse') THEN
        v_transfer_deferred := v_transfer_deferred + 1;
        CONTINUE;
      END IF;
      IF v_action NOT IN ('Refill','Add New') OR line.from_machine_id IS NULL THEN
        v_transfer_skipped := v_transfer_skipped + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('m2m_push_unroutable','warning', jsonb_build_object(
          'title', format('M2M line unroutable at push: %s @ %s', line.boonz_product_name, p_machine_name),
          'plan_line_id', line.id, 'plan_date', p_plan_date, 'action', v_action,
          'from_machine_id', line.from_machine_id,
          'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
        CONTINUE;
      END IF;
      BEGIN
        SELECT rpo.* INTO v_src_line
          FROM refill_plan_output rpo
          JOIN machines sm ON sm.machine_id = line.from_machine_id AND sm.official_name = rpo.machine_name
         WHERE rpo.plan_date = line.plan_date
           AND rpo.source_origin = 'internal_transfer'
           AND upper(trim(rpo.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
           AND lower(trim(rpo.pod_product_name)) = lower(trim(line.pod_product_name))
           AND rpo.quantity = line.quantity
           AND rpo.operator_status = 'approved' AND rpo.dispatched = false
         ORDER BY rpo.id
         LIMIT 1;
        IF NOT FOUND THEN
          v_transfer_skipped := v_transfer_skipped + 1;
          INSERT INTO public.monitoring_alerts (source, severity, payload)
          VALUES ('m2m_push_no_source_line','warning', jsonb_build_object(
            'title', format('M2M dest line has no matching approved source Remove: %s @ %s', line.boonz_product_name, p_machine_name),
            'plan_line_id', line.id, 'plan_date', p_plan_date, 'qty', line.quantity,
            'from_machine_id', line.from_machine_id,
            'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
          CONTINUE;
        END IF;

        v_src_machine_id := line.from_machine_id;
        v_src_normalized_shelf := regexp_replace(v_src_line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
        v_src_shelf_id := v_src_line.shelf_id;
        IF v_src_shelf_id IS NULL THEN
          SELECT shelf_id INTO v_src_shelf_id FROM shelf_configurations
           WHERE machine_id = v_src_machine_id AND shelf_code = v_src_normalized_shelf;
        END IF;

        v_transfer_id := gen_random_uuid();
        v_first_remove_id := NULL;
        v_earliest_expiry := NULL;
        v_remaining := line.quantity;

        FOR v_batch IN
          SELECT pil.expiration_date, pil.current_stock
            FROM public.v_pod_inventory_latest pil
           WHERE pil.machine_id = v_src_machine_id
             AND pil.shelf_id   = v_src_shelf_id
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
            is_m2m, m2m_transfer_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
            line.plan_date, 'Remove', v_take, true,
            COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name)),
            NULL, NULL, v_batch.expiration_date, false,
            'internal_transfer'::public.source_origin_enum, NULL,
            true, v_transfer_id, v_src_machine_id, 'm2m',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;
          IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;
          IF v_earliest_expiry IS NULL THEN v_earliest_expiry := v_batch.expiration_date; END IF;
          v_remaining := v_remaining - v_take;
          v_count := v_count + 1;
        END LOOP;
        IF v_remaining > 0 THEN
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id,
            is_m2m, m2m_transfer_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
            line.plan_date, 'Remove', v_remaining, true,
            format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name) || E'\n' || '[EXPIRY-TO-CONFIRM - remainder not attributable to a known batch (PRD-053)]',
            NULL, NULL, NULL, false,
            'internal_transfer'::public.source_origin_enum, NULL,
            true, v_transfer_id, v_src_machine_id, 'm2m',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;
          IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;
          v_count := v_count + 1;
        END IF;

        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id,
          is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id, source_kind,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, line.quantity, true,
          COALESCE(NULLIF(trim(v_dispatch_comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name)),
          NULL, NULL, v_earliest_expiry, false,
          'internal_transfer'::public.source_origin_enum, v_src_machine_id,
          true, v_transfer_id, v_first_remove_id, v_src_machine_id, 'm2m',
          true, false, false, false, false
        ) RETURNING dispatch_id INTO v_dest_leg_id;

        UPDATE refill_dispatching SET m2m_partner_id = v_dest_leg_id
         WHERE m2m_transfer_id = v_transfer_id AND dispatch_id <> v_dest_leg_id;

        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_dest_leg_id WHERE id = line.id;
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_first_remove_id WHERE id = v_src_line.id;
        v_count := v_count + 1;
        v_transfer_pairs := v_transfer_pairs + 1;
      EXCEPTION WHEN OTHERS THEN
        v_transfer_skipped := v_transfer_skipped + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('m2m_push_pair_failure','warning', jsonb_build_object(
          'title', format('M2M paired insert failed at push: %s @ %s', line.boonz_product_name, p_machine_name),
          'plan_line_id', line.id, 'plan_date', p_plan_date, 'error', SQLERRM,
          'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
      END;
      CONTINUE;
    END IF;

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

    v_pin_eligible := (v_action IN ('Refill','Add New'))
                      AND (COALESCE(line.source_origin::text, 'warehouse') = 'warehouse');
    v_pinned_wh_id := NULL;
    v_pinned_expiry := NULL;
    v_pinned_route_wh := NULL;

    -- RC-01 §7 / B1(c): resolve the route warehouse for THIS line. Cold-chain lines
    -- route to WH_CENTRAL (real cold stock lives only there); ambient lines keep the
    -- machine's primary warehouse (preserves the current push routing). This RE-ADDS
    -- the cold->central routing that approve Step-3 used to supply, now that push is
    -- the sole writer. Ambient stays primary-only (matches pre-RC-01 push).
    SELECT storage_temp_requirement INTO v_storage_temp
      FROM boonz_products WHERE product_id = v_boonz_product_id;
    v_line_wh_id := CASE WHEN v_storage_temp = 'cold' THEN public.wh_central_id()
                         ELSE v_primary_warehouse_id END;

    IF v_pin_eligible AND v_line_wh_id IS NOT NULL THEN
      -- RC-01/RC-08 B1: canonical FEFO coverage — machine-scoped, reservation-aware,
      -- quarantine-excluded, expiry-valid as of plan_date, NET of other-machine live
      -- warehouse commitments (reserved_by_earlier reuse). Pin the EFFECTIVE FEFO-front
      -- batch (running > committed) ONLY when the netted route pool is satisfiable.
      SELECT f.wh_inventory_id, f.expiration_date, f.warehouse_id
        INTO v_pinned_wh_id, v_pinned_expiry, v_pinned_route_wh
      FROM public.wh_fefo_for_line(
             v_machine_id, v_boonz_product_id, line.plan_date, line.quantity,
             ARRAY[v_line_wh_id]) f
      WHERE f.is_satisfiable
        AND f.running_pickable > f.committed_elsewhere
      ORDER BY f.pick_rank
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
            'wh_id', v_line_wh_id, 'action', v_action, 'qty_needed', line.quantity,
            'detected_by', 'push_plan_to_dispatch_FEFO_pin_rc01', 'detected_at', now()
          )
        );
      ELSE
        v_pinned_count := v_pinned_count + 1;
      END IF;
    END IF;

    -- RC-01 §3b: idempotent upsert on the partial arbiter. A conflict can only occur
    -- against an UNSTARTED row (index excludes packed/started), so DO UPDATE never
    -- touches a packed row (never trips protect_packed_dispatch_row). from_warehouse_id
    -- is the routed WH (cold->central), replacing the old always-primary value.
    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
      source_origin, from_machine_id,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES (
      v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
      line.plan_date, v_action, line.quantity, true, v_dispatch_comment,
      v_line_wh_id, v_pinned_wh_id, v_pinned_expiry, v_pin_eligible,
      COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
      CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
      false, false, false, false, false
    )
    ON CONFLICT (dispatch_date, machine_id, shelf_id, boonz_product_id, action)
      WHERE ( include = true AND action IN ('Refill','Add New')
              AND COALESCE(filled_quantity,0)=0
              AND packed=false AND item_added=false AND returned=false
              AND skipped=false AND cancelled=false
              AND created_by_edit=false AND is_m2m=false )
    DO UPDATE SET
      quantity             = EXCLUDED.quantity,
      comment              = EXCLUDED.comment,
      from_wh_inventory_id = EXCLUDED.from_wh_inventory_id,
      expiry_date          = EXCLUDED.expiry_date,
      pinned_at_plan_time  = EXCLUDED.pinned_at_plan_time,
      from_warehouse_id    = EXCLUDED.from_warehouse_id
    RETURNING dispatch_id INTO v_new_dispatch_id;

    UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
    v_count := v_count + 1;
  END LOOP;

  -- PRD-071 WS-B: safety-net pairing pass (idempotent; failure logs, never fails the push)
  v_prev_via_trigger := current_setting('app.via_trigger', true);
  v_prev_mutation_reason := current_setting('app.mutation_reason', true);
  BEGIN
    v_pairing := public.pair_internal_transfer_m2m(p_plan_date, v_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_pairing := jsonb_build_object('status','error','error', SQLERRM);
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('m2m_pairing_failure', 'warning', jsonb_build_object(
      'title', format('M2M auto-pairing failed on push: %s @ %s', p_machine_name, p_plan_date),
      'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
      'error', SQLERRM, 'detected_by', 'push_plan_to_dispatch_v7_prd071', 'detected_at', now()));
  END;
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);
  PERFORM set_config('app.via_trigger', COALESCE(v_prev_via_trigger, ''), true);
  PERFORM set_config('app.mutation_reason', COALESCE(v_prev_mutation_reason, ''), true);

  RETURN jsonb_build_object(
    'status','ok',
    'machine', p_machine_name,
    'lines_pushed', v_count,
    'lines_skipped_null_product', v_skipped,
    'lines_preserved_manual_edit', v_preserved,
    'lines_pinned_at_plan_time', v_pinned_count,
    'remove_split_lines', v_remove_split,
    'procurement_gaps_logged', v_procurement_gaps,
    'm2m_transfer_pairs', v_transfer_pairs,
    'm2m_transfer_deferred', v_transfer_deferred,
    'm2m_transfer_skipped', v_transfer_skipped,
    'm2m_pairing', v_pairing,
    'weimi_slot_guard', v_slot_guard,
    'rpc_version','v10_rc01_single_writer'
  );
END $function$;

COMMIT;
