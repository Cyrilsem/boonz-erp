-- capacity_standard: canonical cap per product x shelf-size (non-AMZ fleet)
CREATE TABLE IF NOT EXISTS public.capacity_standard (
  product     text NOT NULL,
  shelf_size  text NOT NULL CHECK (shelf_size IN ('Small','Medium','Large')),
  target_cap  integer NOT NULL CHECK (target_cap > 0),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  text NOT NULL DEFAULT current_user,
  PRIMARY KEY (product, shelf_size)
);
ALTER TABLE public.capacity_standard ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cap_std_read ON public.capacity_standard;
CREATE POLICY cap_std_read ON public.capacity_standard FOR SELECT
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['field_staff','warehouse','operator_admin','superadmin','manager'])));

-- capacity_drift_log: tracks discrepancies vs standard, with first_detected_at
CREATE TABLE IF NOT EXISTS public.capacity_drift_log (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  machine_name      text NOT NULL,
  aisle_code        text NOT NULL,
  slot_name         text,
  product           text,
  shelf_size        text,
  standard_cap      integer,
  observed_cap      integer,
  observed_stock    integer,
  category          text,        -- 'drift' | 'blocked_overstock'
  status            text NOT NULL DEFAULT 'open',  -- 'open' | 'resolved'
  first_detected_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_capacity_drift_open
  ON public.capacity_drift_log (machine_name, aisle_code) WHERE status='open';
ALTER TABLE public.capacity_drift_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cap_drift_read ON public.capacity_drift_log;
CREATE POLICY cap_drift_read ON public.capacity_drift_log FOR SELECT
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['field_staff','warehouse','operator_admin','superadmin','manager'])));

-- validator: compares live caps to standard (active, non-AMZ, mapped),
-- logs drift with first_detected_at, resolves cleared rows, returns open discrepancies.
CREATE OR REPLACE FUNCTION public.validate_capacity_standard()
RETURNS TABLE (
  machine_name text, aisle_code text, slot_name text, product text, shelf_size text,
  standard_cap int, observed_cap int, observed_stock int, category text,
  first_detected_at timestamptz, days_open numeric
)
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  CREATE TEMP TABLE _cur ON COMMIT DROP AS
  SELECT vls.machine_name, vls.aisle_code, vls.slot_name,
         btrim(vls.goods_name_raw) AS product, cs.shelf_size,
         cs.target_cap AS standard_cap, vls.max_stock AS observed_cap,
         vls.current_stock AS observed_stock,
         CASE WHEN vls.current_stock > cs.target_cap THEN 'blocked_overstock' ELSE 'drift' END AS category
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
     AND NOT EXISTS (SELECT 1 FROM _cur c WHERE c.machine_name=l.machine_name AND c.aisle_code=l.aisle_code);

  INSERT INTO capacity_drift_log
    (machine_name,aisle_code,slot_name,product,shelf_size,standard_cap,observed_cap,observed_stock,category)
  SELECT machine_name,aisle_code,slot_name,product,shelf_size,standard_cap,observed_cap,observed_stock,category
  FROM _cur
  ON CONFLICT (machine_name,aisle_code) WHERE (status='open')
  DO UPDATE SET last_seen_at=now(), observed_cap=EXCLUDED.observed_cap,
                observed_stock=EXCLUDED.observed_stock, standard_cap=EXCLUDED.standard_cap,
                category=EXCLUDED.category;

  RETURN QUERY
  SELECT l.machine_name,l.aisle_code,l.slot_name,l.product,l.shelf_size,l.standard_cap,
         l.observed_cap,l.observed_stock,l.category,l.first_detected_at,
         round(extract(epoch from (now()-l.first_detected_at))/86400,1) AS days_open
  FROM capacity_drift_log l WHERE l.status='open'
  ORDER BY l.first_detected_at, l.machine_name, l.aisle_code;
END;$$;
