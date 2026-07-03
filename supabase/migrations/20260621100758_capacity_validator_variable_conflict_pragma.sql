CREATE OR REPLACE FUNCTION public.validate_capacity_standard()
RETURNS TABLE (
  machine_name text, aisle_code text, slot_name text, product text, shelf_size text,
  standard_cap int, observed_cap int, observed_stock int, category text,
  first_detected_at timestamptz, days_open numeric
)
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  CREATE TEMP TABLE _cur ON COMMIT DROP AS
  SELECT vls.machine_name AS m_name, vls.aisle_code AS a_code, vls.slot_name AS s_name,
         btrim(vls.goods_name_raw) AS prod, cs.shelf_size AS s_size,
         cs.target_cap AS std_cap, vls.max_stock AS obs_cap,
         vls.current_stock AS obs_stock,
         CASE WHEN vls.current_stock > cs.target_cap THEN 'blocked_overstock' ELSE 'drift' END AS cat
  FROM v_live_shelf_stock vls
  JOIN machines m ON m.machine_id = vls.machine_id AND m.include_in_refill = true
  JOIN capacity_standard cs
    ON cs.product = btrim(vls.goods_name_raw)
   AND cs.shelf_size = CASE
        WHEN (split_part(vls.aisle_code,'-A',2))::int+1 BETWEEN 1 AND 8 THEN 'Small'
        WHEN (split_part(vls.aisle_code,'-A',2))::int+1 BETWEEN 9 AND 14 THEN 'Medium'
        ELSE 'Large' END
  WHERE vls.pod_product_id IS NOT NULL
    AND vls.machine_name NOT LIKE 'AMZ%'
    AND vls.max_stock <> cs.target_cap;

  UPDATE capacity_drift_log l SET status='resolved', resolved_at=now()
   WHERE l.status='open'
     AND NOT EXISTS (SELECT 1 FROM _cur c WHERE c.m_name=l.machine_name AND c.a_code=l.aisle_code);

  INSERT INTO capacity_drift_log
    (machine_name,aisle_code,slot_name,product,shelf_size,standard_cap,observed_cap,observed_stock,category)
  SELECT c.m_name,c.a_code,c.s_name,c.prod,c.s_size,c.std_cap,c.obs_cap,c.obs_stock,c.cat
  FROM _cur c
  ON CONFLICT (machine_name,aisle_code) WHERE (status='open')
  DO UPDATE SET last_seen_at=now(), observed_cap=EXCLUDED.observed_cap,
                observed_stock=EXCLUDED.observed_stock, standard_cap=EXCLUDED.standard_cap,
                category=EXCLUDED.category;

  RETURN QUERY
  SELECT l.machine_name,l.aisle_code,l.slot_name,l.product,l.shelf_size,l.standard_cap,
         l.observed_cap,l.observed_stock,l.category,l.first_detected_at,
         round(extract(epoch from (now()-l.first_detected_at))/86400,1)
  FROM capacity_drift_log l WHERE l.status='open'
  ORDER BY l.first_detected_at, l.machine_name, l.aisle_code;
END;$$;
