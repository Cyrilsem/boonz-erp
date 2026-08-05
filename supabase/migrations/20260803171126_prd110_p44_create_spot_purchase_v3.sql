-- PRD-110 P4.4 migration B - public.create_spot_purchase_v3
--
-- One transaction = PO create (or attach) + receive into the REQUESTED warehouse
-- + auto-close the walk-in driver task + FEFO-bind the waiting dispatch lines
-- + resolve blocked_demand. Composes the incumbent writers; edits none of them
-- (Article 3), which is the condition Cody's verdict rests on.
--
-- Design: docs/prds/PRD-110-P4.4-DARA-spot-buy-design.md (leg 90) with SIX
-- live-code corrections found and recorded by leg 91 (S-141..S-147):
--   S-141 L1 receive_purchase_order HARDCODES wh_central_id() -> own receive path
--   S-142 L2 walk_in forces a pending driver_task -> auto-close, never DELETE
--   S-143 L3 bind_dispatch_fefo(NULL) sweeps the FLEET -> always machine-scoped
--   S-144 bind_dispatch_fefo REFUSES field_staff -> this RPC gates at warehouse+
--   S-145 add_purchase_order_lines is owner-only -> attach only for owners
--   S-146 inventory_events is machine+shelf NOT NULL -> no event on a WH receive
--   S-147 driver_tasks.status has NO 'completed' -> terminal state is 'collected'

CREATE OR REPLACE FUNCTION public.create_spot_purchase_v3(
  p_machine_id    uuid,
  p_warehouse_id  uuid,
  p_supplier_id   uuid,
  p_lines         jsonb,
  p_dispatch_date date    DEFAULT NULL,
  p_receipt_photo text    DEFAULT NULL,
  p_po_id         text    DEFAULT NULL,
  p_note          text    DEFAULT NULL,
  p_dry_run       boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_caller        uuid;
  v_role          text;
  v_today         date := CURRENT_DATE;
  v_dispatch      date;
  v_sup_type      text;
  v_sup_status    text;
  v_machine_name  text;
  v_line          jsonb;
  v_idx           int := 0;
  v_cap           numeric;
  v_enf           text;
  v_warnings      text[] := '{}';
  v_po_id         text;
  v_po_number     int;
  v_po_path       text;
  v_create_lines  jsonb;
  v_created       jsonb;
  v_tasks_closed  int := 0;
  v_po_line_id    uuid;
  v_product       uuid;
  v_prod_name     text;
  v_qty           numeric;
  v_price         numeric;
  v_exp           date;
  v_batch_id      text;
  v_recv_lines    int := 0;
  v_recv_units    numeric := 0;
  v_spend         numeric := 0;
  v_bind          jsonb := NULL;
  v_blk_resolved  int := 0;
  v_blk_partial   int := 0;
  v_remaining     numeric;
  v_b             record;
  v_result        jsonb;
  v_prev_via      text;
  v_prev_rpc      text;
  v_prev_prov     text;
BEGIN
  -- Article 4 (PRD-016B): the app.* GUCs leak across statements. Capture the
  -- inbound values now and RESTORE them on every exit path.
  v_prev_via  := current_setting('app.via_rpc', true);
  v_prev_rpc  := current_setting('app.rpc_name', true);
  v_prev_prov := current_setting('app.provenance_reason', true);

  BEGIN
    ------------------------------------------------------------------ 1. gate
    v_caller := (SELECT auth.uid());
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;

    -- S-144. NOT field_staff. bind_dispatch_fefo refuses field_staff outright,
    -- and this RPC performs a warehouse RECEIVE, which receive_purchase_order
    -- also gates at warehouse+. A new RPC must never hand a role a power its
    -- own component writers deny. The driver-facing path is P4.4b (post-facto).
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'create_spot_purchase_v3: role % not authorized (warehouse+ only; the driver-facing path is P4.4b)',
        COALESCE(v_role,'none');
    END IF;

    -------------------------------------------------------------- 2. validate
    IF p_warehouse_id IS NULL THEN
      RAISE EXCEPTION 'create_spot_purchase_v3: p_warehouse_id is REQUIRED (S-141: there is no safe default; receive_purchase_order hardcodes CENTRAL and the binder would then look elsewhere)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.warehouses WHERE warehouse_id = p_warehouse_id) THEN
      RAISE EXCEPTION 'create_spot_purchase_v3: warehouse % not found', p_warehouse_id;
    END IF;

    SELECT procurement_type, status INTO v_sup_type, v_sup_status
      FROM public.suppliers WHERE supplier_id = p_supplier_id;
    IF v_sup_type IS NULL AND v_sup_status IS NULL THEN
      RAISE EXCEPTION 'create_spot_purchase_v3: supplier % not found', p_supplier_id;
    END IF;
    IF v_sup_status IS DISTINCT FROM 'Active' THEN
      RAISE EXCEPTION 'create_spot_purchase_v3: supplier % is % - Active required', p_supplier_id, COALESCE(v_sup_status,'NULL');
    END IF;
    IF v_sup_type IS DISTINCT FROM 'walk_in' THEN
      RAISE EXCEPTION 'create_spot_purchase_v3: supplier % is procurement_type % - a spot buy is walk_in by definition', p_supplier_id, COALESCE(v_sup_type,'NULL');
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
      RAISE EXCEPTION 'create_spot_purchase_v3: at least one line is required';
    END IF;

    IF p_machine_id IS NOT NULL THEN
      SELECT official_name INTO v_machine_name FROM public.machines WHERE machine_id = p_machine_id;
      IF v_machine_name IS NULL THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: machine % not found', p_machine_id;
      END IF;
    END IF;

    v_dispatch := COALESCE(p_dispatch_date, public.resolve_refill_plan_date());

    SELECT spot_buy_price_cap_aed, spot_buy_cap_enforcement INTO v_cap, v_enf
      FROM public.refill_policy_params LIMIT 1;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_idx     := v_idx + 1;
      v_product := NULLIF(v_line->>'boonz_product_id','')::uuid;
      v_qty     := COALESCE((v_line->>'qty')::numeric, 0);
      v_price   := NULLIF(v_line->>'price_per_unit_aed','')::numeric;
      v_exp     := NULLIF(v_line->>'expiry_date','')::date;

      IF v_product IS NULL THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: line %: boonz_product_id is required', v_idx;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.boonz_products WHERE product_id = v_product) THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: line %: boonz_product_id % not found', v_idx, v_product;
      END IF;
      IF v_qty <= 0 THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: line %: qty must be > 0 (got %)', v_idx, v_qty;
      END IF;
      -- EXPIRY IRON RULE / BUG-007/009: the spot path must not become the hole
      -- through which NULL-expiry rows enter warehouse_inventory.
      IF v_exp IS NULL THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: line %: expiry_date is REQUIRED (NULL-expiry warehouse rows are forbidden, BUG-007/009). If the driver cannot read it, that is a verify task - not a NULL.', v_idx;
      END IF;
      IF v_exp < v_today THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: line %: expiry_date % is in the past', v_idx, v_exp;
      END IF;

      -- D-D pre-auth cap. Ships enforced-as-warn; the flip to block is parked.
      IF v_price IS NOT NULL AND v_enf <> 'off' AND v_price > v_cap THEN
        IF v_enf = 'block' THEN
          RAISE EXCEPTION 'create_spot_purchase_v3: line %: price %.2f AED exceeds spot_buy_price_cap_aed %.2f and spot_buy_cap_enforcement=block', v_idx, v_price, v_cap;
        END IF;
        v_warnings := array_append(v_warnings,
          format('line %s: price %s AED over cap %s AED', v_idx, v_price, v_cap));
      END IF;

      v_spend := v_spend + COALESCE(v_price,0) * v_qty;
    END LOOP;

    -- lines in the incumbent creator's vocabulary
    SELECT jsonb_agg(jsonb_build_object(
             'boonz_product_id',   l->>'boonz_product_id',
             'ordered_qty',        (l->>'qty')::numeric,
             'price_per_unit_aed', NULLIF(l->>'price_per_unit_aed','')::numeric,
             'expiry_date',        l->>'expiry_date'))
      INTO v_create_lines
      FROM jsonb_array_elements(p_lines) l;

    --------------------------------------------------------- 3. resolve the PO
    IF p_po_id IS NOT NULL AND trim(p_po_id) <> '' THEN
      IF NOT EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_id = p_po_id) THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: p_po_id % not found', p_po_id;
      END IF;
      v_po_id   := p_po_id;
      v_po_path := 'explicit';
      PERFORM public.add_purchase_order_lines(v_po_id, v_create_lines);
    ELSE
      SELECT po.po_id INTO v_po_id
        FROM public.purchase_orders po
       WHERE po.supplier_id   = p_supplier_id
         AND po.purchase_date = v_today
         AND po.received_date IS NULL
         AND COALESCE(po.purchase_outcome,'') <> 'not_purchased'
       ORDER BY po.po_number DESC
       LIMIT 1;

      -- S-145: add_purchase_order_lines is owner-only (operator_admin/superadmin).
      -- A warehouse caller therefore mints a fresh PO rather than attaching, and
      -- is TOLD so - silently dropping the attach would look like a duplicate PO.
      IF v_po_id IS NOT NULL AND v_role IN ('operator_admin','superadmin') THEN
        v_po_path := 'attached';
        PERFORM public.add_purchase_order_lines(v_po_id, v_create_lines);
      ELSE
        IF v_po_id IS NOT NULL THEN
          v_warnings := array_append(v_warnings,
            format('an open walk-in PO (%s) exists today but attaching is owner-only for role %s - minted a new PO instead', v_po_id, v_role));
        END IF;
        v_po_id   := 'PO-' || to_char(v_today,'YYYY') || '-SPOT'
                     || upper(left(replace(gen_random_uuid()::text,'-',''),8));
        v_po_path := 'minted';
        -- the incumbent owns po_number_seq self-healing, the PRD-1 blocked-product
        -- guardrail and procurement_events. A spot buy of a decommissioned product
        -- must fail exactly as a planned order does.
        v_created := public.create_purchase_order(v_po_id, p_supplier_id, v_today, v_create_lines, false);
      END IF;
    END IF;

    SELECT po_number INTO v_po_number FROM public.purchase_orders WHERE po_id = v_po_id LIMIT 1;

    ------------------------------------------------- 4. S-142 close the task
    -- The walk-in supplier forced a 'pending' task telling a driver to go buy
    -- goods he is already holding. Close it, never DELETE it (Article 7).
    -- S-147: there is no 'completed' in the status CHECK - 'collected' is the
    -- terminal state, and it is literally true here.
    UPDATE public.driver_tasks
       SET status          = 'collected',
           collected_at    = COALESCE(collected_at, now()),
           outcome         = COALESCE(outcome, 'purchased_full'),
           outcome_comment = COALESCE(outcome_comment,'')
                             || '[auto-closed by create_spot_purchase_v3: goods already purchased at the counter]'
     WHERE po_id = v_po_id
       AND status IN ('pending','acknowledged');
    GET DIAGNOSTICS v_tasks_closed = ROW_COUNT;

    IF v_tasks_closed > 0 THEN
      INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
      VALUES (v_po_id, 'spot_purchase_task_autoclosed', v_caller,
              jsonb_build_object('tasks_closed', v_tasks_closed, 'reason', 'goods already purchased at the counter'));
    END IF;

    ------------------------------------------- 5. S-141 receive, OUR warehouse
    v_idx := 0;
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_idx     := v_idx + 1;
      v_product := (v_line->>'boonz_product_id')::uuid;
      v_qty     := (v_line->>'qty')::numeric;
      v_price   := NULLIF(v_line->>'price_per_unit_aed','')::numeric;
      v_exp     := (v_line->>'expiry_date')::date;

      SELECT po_line_id INTO v_po_line_id
        FROM public.purchase_orders
       WHERE po_id = v_po_id
         AND boonz_product_id = v_product
         AND received_date IS NULL
       ORDER BY po_line_id
       LIMIT 1;
      IF v_po_line_id IS NULL THEN
        RAISE EXCEPTION 'create_spot_purchase_v3: no open PO line for product % on PO %', v_product, v_po_id;
      END IF;

      PERFORM set_config('app.via_rpc','true', true);
      PERFORM set_config('app.rpc_name','create_spot_purchase_v3', true);
      PERFORM set_config('app.provenance_reason','po_receive', true);
      PERFORM set_config('app.source_event_id', v_po_line_id::text, true);

      -- PO-side effects are column-for-column what receive_purchase_order writes
      UPDATE public.purchase_orders
         SET received_date      = v_today,
             received_qty       = v_qty,
             purchase_outcome   = 'received',
             price_per_unit_aed = COALESCE(v_price, price_per_unit_aed),
             total_price_aed    = CASE
                                    WHEN v_price IS NOT NULL THEN v_qty * v_price
                                    WHEN price_per_unit_aed IS NOT NULL THEN v_qty * price_per_unit_aed
                                    ELSE NULL END,
             expiry_date        = COALESCE(v_exp, expiry_date)
       WHERE po_line_id = v_po_line_id;

      v_batch_id := v_po_id || '-' || left(v_po_line_id::text,8) || '-SPOT-B' || v_idx;

      -- Article 6: INSERT a NEW Active batch. Never UPDATE status on an existing
      -- row - a spot buy does not resurrect an Inactive one.
      INSERT INTO public.warehouse_inventory (
        boonz_product_id, warehouse_stock, expiration_date,
        batch_id, wh_location, status, snapshot_date, warehouse_id
      ) VALUES (
        v_product, v_qty, v_exp,
        v_batch_id, NULLIF(v_line->>'wh_location',''), 'Active', v_today, p_warehouse_id
      );

      -- S-146: NO inventory_events row here. That table is machine+shelf grained
      -- (both NOT NULL, plus tg_assert_shelf_machine_match). A warehouse receive
      -- is not a shelf-composition fact, and inventing a shelf_id to satisfy the
      -- constraint would poison the P1.4 estimator. 'spot_buy_receive' belongs to
      -- the moment spot goods enter a SHELF - i.e. P4.4b's post-facto flow.

      v_recv_lines := v_recv_lines + 1;
      v_recv_units := v_recv_units + v_qty;
    END LOOP;

    ------------------------------------------------- 6. S-143 bind, MACHINE-scoped
    IF p_machine_id IS NOT NULL THEN
      -- NEVER NULL: bind_dispatch_fefo(NULL) is a fleet-wide sweep and would bind
      -- other machines' lines to this driver's Carrefour batch.
      v_bind := public.bind_dispatch_fefo(v_dispatch, ARRAY[v_machine_name], v_caller);
    END IF;

    ------------------------------------------------------ 7. blocked_demand
    IF p_machine_id IS NOT NULL THEN
      v_idx := 0;
      FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_idx       := v_idx + 1;
        v_product   := (v_line->>'boonz_product_id')::uuid;
        v_remaining := (v_line->>'qty')::numeric;

        FOR v_b IN
          SELECT blocked_demand_id, qty_blocked
            FROM public.blocked_demand
           WHERE machine_id = p_machine_id
             AND boonz_product_id = v_product
             AND resolved_at IS NULL
           ORDER BY created_at, blocked_demand_id
        LOOP
          EXIT WHEN v_remaining <= 0;

          IF v_b.qty_blocked <= v_remaining THEN
            UPDATE public.blocked_demand
               SET resolved_at     = now(),
                   resolution      = 'spot_buy',
                   resolved_by     = v_caller,
                   resolution_note = format('spot buy %s: %s units received into warehouse %s', v_po_id, v_remaining, p_warehouse_id)
             WHERE blocked_demand_id = v_b.blocked_demand_id;
            v_remaining   := v_remaining - v_b.qty_blocked;
            v_blk_resolved := v_blk_resolved + 1;
          ELSE
            -- LAW 5: a 4-unit spot buy does NOT close a 10-unit block. Leave it
            -- OPEN (resolved_at/resolution stay NULL) and record the shortfall.
            UPDATE public.blocked_demand
               SET resolution_note = format('PARTIAL: spot buy %s covered %s of %s units; %s still outstanding',
                                            v_po_id, v_remaining, v_b.qty_blocked, v_b.qty_blocked - v_remaining)
             WHERE blocked_demand_id = v_b.blocked_demand_id;
            v_blk_partial := v_blk_partial + 1;
            v_remaining   := 0;
          END IF;
        END LOOP;
      END LOOP;
    END IF;

    ------------------------------------------------------------- 8. event log
    INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
    VALUES (v_po_id, 'spot_purchase_created', v_caller,
      jsonb_build_object(
        'po_number', v_po_number, 'po_path', v_po_path,
        'machine_id', p_machine_id, 'warehouse_id', p_warehouse_id,
        'supplier_id', p_supplier_id, 'dispatch_date', v_dispatch,
        'lines_received', v_recv_lines, 'units_received', v_recv_units,
        'spend_aed', v_spend, 'receipt_photo', p_receipt_photo,
        'note', p_note, 'warnings', to_jsonb(v_warnings),
        'blocked_resolved', v_blk_resolved, 'blocked_partial', v_blk_partial,
        'bind', v_bind));

    v_result := jsonb_build_object(
      'ok', true,
      'po_id', v_po_id, 'po_number', v_po_number, 'po_path', v_po_path,
      'warehouse_id', p_warehouse_id, 'machine_id', p_machine_id,
      'dispatch_date', v_dispatch,
      'lines_received', v_recv_lines, 'units_received', v_recv_units,
      'spend_aed', v_spend,
      'driver_tasks_closed', v_tasks_closed,
      'blocked_demand_resolved', v_blk_resolved,
      'blocked_demand_partial', v_blk_partial,
      'bind', v_bind,
      -- surfaced, never swallowed: a spot buy of the wrong item binds nothing
      'still_unbound_no_wh_stock', COALESCE((v_bind->>'still_unbound_no_wh_stock')::int, NULL),
      'cap_aed', v_cap, 'cap_enforcement', v_enf,
      'warnings', to_jsonb(v_warnings),
      'dry_run', p_dry_run, 'committed', true);

    IF p_dry_run THEN
      RAISE EXCEPTION 'PRD110_P44_DRY_RUN';
    END IF;

  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.via_rpc',            COALESCE(v_prev_via,''),  true);
    PERFORM set_config('app.rpc_name',           COALESCE(v_prev_rpc,''),  true);
    PERFORM set_config('app.provenance_reason',  COALESCE(v_prev_prov,''), true);

    IF SQLERRM = 'PRD110_P44_DRY_RUN' THEN
      RETURN v_result || jsonb_build_object(
        'dry_run', true, 'committed', false,
        'deferred_constraints_unchecked', true,
        'note', 'S-133: a rolled-back dry run does NOT check DEFERRED constraints');
    END IF;
    RAISE;
  END;

  -- Article 4: restore on the success path too.
  PERFORM set_config('app.via_rpc',           COALESCE(v_prev_via,''),  true);
  PERFORM set_config('app.rpc_name',          COALESCE(v_prev_rpc,''),  true);
  PERFORM set_config('app.provenance_reason', COALESCE(v_prev_prov,''), true);

  RETURN v_result;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.create_spot_purchase_v3(uuid,uuid,uuid,jsonb,date,text,text,text,boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_spot_purchase_v3(uuid,uuid,uuid,jsonb,date,text,text,text,boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.create_spot_purchase_v3(uuid,uuid,uuid,jsonb,date,text,text,text,boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.create_spot_purchase_v3(uuid,uuid,uuid,jsonb,date,text,text,text,boolean) IS
  'PRD-110 P4.4: atomic spot buy. PO create/attach + receive into the REQUESTED warehouse + auto-close the walk-in driver task + machine-scoped FEFO bind + blocked_demand resolution. warehouse+ only (S-144). Writes no inventory_events (S-146).';

-- S-140: read the ACL BACK and assert the whole string. A REVOKE ... FROM PUBLIC
-- removes nothing here; the anon revoke above is the one that matters.
DO $$
DECLARE
  v_acl   text;
  v_n     int;
  v_sec   boolean;
  v_cfg   text[];
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='create_spot_purchase_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'P4.4 B FAILED: expected exactly 1 overload, found %', v_n;
  END IF;

  SELECT p.proacl::text, p.prosecdef, p.proconfig
    INTO v_acl, v_sec, v_cfg
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='create_spot_purchase_v3';

  IF NOT v_sec THEN
    RAISE EXCEPTION 'P4.4 B FAILED: function is not SECURITY DEFINER';
  END IF;
  IF v_cfg IS NULL OR NOT ('search_path=public, pg_temp' = ANY(v_cfg)) THEN
    RAISE EXCEPTION 'P4.4 B FAILED: search_path not pinned, proconfig=%', v_cfg;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'P4.4 B FAILED: anon can EXECUTE, acl=%', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X/%' OR v_acl NOT LIKE '%service_role=X/%' THEN
    RAISE EXCEPTION 'P4.4 B FAILED: expected grants missing, acl=%', v_acl;
  END IF;

  RAISE NOTICE 'P4.4 B OK: acl=% secdef=% cfg=%', v_acl, v_sec, v_cfg;
END $$;
