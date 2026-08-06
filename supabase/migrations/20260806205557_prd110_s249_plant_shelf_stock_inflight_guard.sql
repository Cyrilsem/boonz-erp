-- PRD-110 · S-249 · leg 136 · S-252
-- golden.plant_shelf_stock shipped WITHOUT the fixture-only guard that every other golden
-- WEIMI-writer carries (arrange_shelf leg 27, pin_machine_stock, restore_machine_stock).
-- A COMMENT is documentation, not enforcement: called outside a fixture the function would
-- rewrite a live WEIMI observation and never restore it. Same predicate as the precedent.
--
-- Forward-only (Article 12): the previous migration stays as applied; this one adds the guard.
CREATE OR REPLACE FUNCTION golden.plant_shelf_stock(p_shelf_id uuid, p_stock integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $fn$
DECLARE
  v_dev     text;
  v_code    text;
  v_show    text;
  v_sid     uuid;
  v_ci      int; v_li int; v_ai int;
  v_matches int;
  v_planted int := 0;
  v_seen    int;
BEGIN
  -- FIXTURE-ONLY GUARD (identical predicate to golden.arrange_shelf, leg 27, and
  -- golden.pin_machine_stock). golden.run_fixture INSERTs its run row with finished_at NULL
  -- BEFORE executing scenario_sql and UPDATEs it at the end of the SAME transaction, so an
  -- unfinished row is visible if and only if a golden run is in flight. No production path
  -- ever has one.
  IF NOT EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL) THEN
    RAISE EXCEPTION 'golden.plant_shelf_stock: REFUSED - no golden run is in flight. This '
      'function mutates a live WEIMI observation; it is legal only inside a golden fixture '
      'scenario, whose probe block rolls it back before the transaction commits.';
  END IF;

  IF p_stock IS NULL OR p_stock < 0 THEN
    RAISE EXCEPTION 'plant_shelf_stock: refusing negative/NULL stock (%)', p_stock;
  END IF;

  SELECT m.official_name, s.shelf_code
    INTO v_dev, v_code
    FROM public.v_shelf_state s
    JOIN public.machines m ON m.machine_id = s.machine_id
   WHERE s.shelf_id = p_shelf_id;

  IF v_dev IS NULL THEN
    RAISE EXCEPTION 'plant_shelf_stock: shelf % does not resolve to a machine', p_shelf_id;
  END IF;

  -- ZERO-PAD LAW, applied in reverse: shelf_code 'A07' is WEIMI showName 'A7'.
  v_show := regexp_replace(v_code, '^([A-Za-z]+)0*([0-9]+)$', '\1\2');

  SELECT count(*) INTO v_matches
    FROM (SELECT DISTINCT ON (device_name) status_id, door_statuses
            FROM public.weimi_device_status WHERE device_name = v_dev
           ORDER BY device_name, snapshot_at DESC) ws,
      LATERAL jsonb_array_elements(ws.door_statuses)      WITH ORDINALITY cab(value, ci),
      LATERAL jsonb_array_elements(cab.value->'layers')   WITH ORDINALITY layer(value, li),
      LATERAL jsonb_array_elements(layer.value->'aisles') WITH ORDINALITY aisle(value, ai)
   WHERE aisle.value->>'showName' = v_show;

  IF v_matches <> 1 THEN
    RAISE EXCEPTION 'plant_shelf_stock: device % showName % (shelf_code %) matched % aisles, need exactly 1',
      v_dev, v_show, v_code, v_matches;
  END IF;

  SELECT ws.status_id, cab.ci - 1, layer.li - 1, aisle.ai - 1
    INTO v_sid, v_ci, v_li, v_ai
    FROM (SELECT DISTINCT ON (device_name) status_id, door_statuses
            FROM public.weimi_device_status WHERE device_name = v_dev
           ORDER BY device_name, snapshot_at DESC) ws,
      LATERAL jsonb_array_elements(ws.door_statuses)      WITH ORDINALITY cab(value, ci),
      LATERAL jsonb_array_elements(cab.value->'layers')   WITH ORDINALITY layer(value, li),
      LATERAL jsonb_array_elements(layer.value->'aisles') WITH ORDINALITY aisle(value, ai)
   WHERE aisle.value->>'showName' = v_show;

  UPDATE public.weimi_device_status
     SET door_statuses = jsonb_set(door_statuses,
           ARRAY[v_ci::text, 'layers', v_li::text, 'aisles', v_ai::text, 'currStock'],
           to_jsonb(p_stock))
   WHERE status_id = v_sid;
  GET DIAGNOSTICS v_planted = ROW_COUNT;

  -- Read back THROUGH the canonical view, not off the JSONB: what the engine will see is
  -- v_shelf_state, and only that proves the plant actually reached sizing.
  SELECT current_stock INTO v_seen FROM public.v_shelf_state WHERE shelf_id = p_shelf_id;

  IF v_planted <> 1 OR v_seen IS DISTINCT FROM p_stock THEN
    RAISE EXCEPTION 'plant_shelf_stock: plant did not reach sizing (rows=% seen=% wanted=%)',
      v_planted, v_seen, p_stock;
  END IF;

  RETURN v_seen;
END
$fn$;

REVOKE ALL ON FUNCTION golden.plant_shelf_stock(uuid, integer) FROM PUBLIC;
