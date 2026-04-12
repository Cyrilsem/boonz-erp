-- Fix push_plan_to_dispatch: map refill_plan_output.action (uppercase engine values)
-- to the expected refill_dispatching field app values.
--
-- Bug: the previous function used CASE WHEN action = 'Add New' ... which never
-- matched because the engine writes 'ADD NEW', 'REFILL', 'REMOVE' (uppercase).
-- Result: all dispatched rows had action = NULL.
--
-- Fix: normalise via UPPER() comparison and map to the correct display values.

CREATE OR REPLACE FUNCTION public.push_plan_to_dispatch(
  p_plan_date    date,
  p_machine_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_machine_id        uuid;
  v_count             int := 0;
  line                RECORD;
  v_shelf_id          uuid;
  v_pod_product_id    uuid;
  v_boonz_product_id  uuid;
  v_normalized_shelf  text;
  v_action            text;
BEGIN
  SELECT machine_id INTO v_machine_id
  FROM machines WHERE official_name = p_machine_name;

  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Machine not found: ' || p_machine_name);
  END IF;

  FOR line IN
    SELECT * FROM refill_plan_output
    WHERE plan_date    = p_plan_date
      AND machine_name = p_machine_name
      AND operator_status = 'approved'
      AND dispatched   = false
  LOOP
    -- Pad single-digit shelf suffix: 'A1' → 'A01'
    v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\10\2');

    SELECT shelf_id INTO v_shelf_id
    FROM shelf_configurations
    WHERE machine_id = v_machine_id AND shelf_code = v_normalized_shelf;

    SELECT pod_product_id INTO v_pod_product_id
    FROM pod_products
    WHERE lower(trim(pod_product_name)) = lower(trim(line.pod_product_name))
    LIMIT 1;

    SELECT product_id INTO v_boonz_product_id
    FROM boonz_products
    WHERE lower(trim(boonz_product_name)) = lower(trim(line.boonz_product_name))
    LIMIT 1;

    -- Map engine action values to field-app display values.
    -- Engine writes: 'REFILL', 'ADD NEW', 'REMOVE', 'SWAP' etc.
    -- Field app expects: 'Refill', 'Add New', 'Remove'
    v_action := CASE upper(trim(line.action))
      WHEN 'REFILL'   THEN 'Refill'
      WHEN 'ADD NEW'  THEN 'Add New'
      WHEN 'REMOVE'   THEN 'Remove'
      WHEN 'SWAP'     THEN 'Add New'   -- swap ADD half treated as Add New
      ELSE                  'Refill'   -- safe default
    END;

    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES (
      v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
      line.plan_date,
      v_action,
      line.quantity, true, line.comment,
      false, false, false, false, false
    );

    UPDATE refill_plan_output SET dispatched = true WHERE id = line.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('status', 'ok', 'machine', p_machine_name, 'lines_pushed', v_count);
END;
$$;

-- REVOKE from public, GRANT to service_role only (matches existing security model)
REVOKE EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.push_plan_to_dispatch(date, text) TO service_role;
