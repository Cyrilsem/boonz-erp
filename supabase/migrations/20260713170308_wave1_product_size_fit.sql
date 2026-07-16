-- WAVE-1 (Cody-approved): product_size_fit reference table + deterministic seed.
-- New engine-load-bearing reference table (file to Appendix A). RLS mirrors capacity_standard.
CREATE TABLE IF NOT EXISTS public.product_size_fit (
    pod_product_id  uuid    NOT NULL REFERENCES public.pod_products(pod_product_id),
    shelf_size      text    NOT NULL CHECK (shelf_size IN ('Small','Medium','Large')),
    fits            boolean NOT NULL DEFAULT true,
    fit_basis       text,
    machines_seen   int     DEFAULT 0,
    cap_typical     int,
    min_refill_qty  int,
    updated_at      timestamptz DEFAULT now(),
    PRIMARY KEY (pod_product_id, shelf_size)
);

ALTER TABLE public.product_size_fit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS psf_read ON public.product_size_fit;
CREATE POLICY psf_read ON public.product_size_fit
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE user_profiles.id = (SELECT auth.uid() AS uid)
        AND user_profiles.role = ANY (ARRAY['field_staff','warehouse','operator_admin','superadmin','manager'])
    )
  );

INSERT INTO public.product_size_fit
    (pod_product_id, shelf_size, fits, fit_basis, machines_seen, cap_typical, min_refill_qty)
WITH mach AS (
  SELECT machine_id FROM public.machines WHERE official_name NOT LIKE '%V0'
),
occ_raw AS (
  SELECT sl.pod_product_id, sl.machine_id, sl.shelf_code
  FROM public.slot_lifecycle sl JOIN mach m ON m.machine_id = sl.machine_id
  WHERE sl.pod_product_id IS NOT NULL AND sl.shelf_code ~ '^A[0-9]{1,2}$'
  UNION ALL
  SELECT r.pod_product_id, r.machine_id, r.shelf_code
  FROM public.refill_plan_output r JOIN mach m ON m.machine_id = r.machine_id
  WHERE r.pod_product_id IS NOT NULL AND r.shelf_code ~ '^A[0-9]{1,2}$'
  UNION ALL
  SELECT pm.pod_product_id, sc.machine_id, sc.shelf_code
  FROM public.pod_inventory pi
  JOIN public.shelf_configurations sc ON sc.shelf_id = pi.shelf_id
  JOIN mach m ON m.machine_id = sc.machine_id
  JOIN public.product_mapping pm
    ON pm.boonz_product_id = pi.boonz_product_id AND pm.status='Active'
   AND (pm.machine_id = pi.machine_id OR pm.is_global_default = true)
  WHERE pm.pod_product_id IS NOT NULL AND sc.shelf_code ~ '^A[0-9]{1,2}$'
),
occ AS (
  SELECT pod_product_id, machine_id,
    CASE WHEN idx BETWEEN 1 AND 8 THEN 'Small' WHEN idx BETWEEN 9 AND 14 THEN 'Medium'
         WHEN idx BETWEEN 15 AND 16 THEN 'Large' END AS shelf_size
  FROM (SELECT pod_product_id, machine_id, NULLIF(regexp_replace(shelf_code,'^A0*',''),'')::int AS idx FROM occ_raw) z
  WHERE idx BETWEEN 1 AND 16
),
occ_agg AS (SELECT pod_product_id, shelf_size, count(DISTINCT machine_id) AS machines_seen FROM occ GROUP BY 1,2),
cap AS (
  SELECT pp.pod_product_id, cs.shelf_size, max(cs.target_cap) AS target_cap
  FROM public.capacity_standard cs JOIN public.pod_products pp ON pp.pod_product_name = cs.product
  WHERE cs.shelf_size IN ('Small','Medium','Large') GROUP BY 1,2
),
obs AS (
  SELECT r.pod_product_id, r.shelf_size, r.max_stock::numeric AS max_stock FROM (
    SELECT pod_product_id, max_stock,
      CASE WHEN idx BETWEEN 1 AND 8 THEN 'Small' WHEN idx BETWEEN 9 AND 14 THEN 'Medium'
           WHEN idx BETWEEN 15 AND 16 THEN 'Large' END AS shelf_size
    FROM (SELECT r2.pod_product_id, r2.max_stock, NULLIF(regexp_replace(r2.shelf_code,'^A0*',''),'')::int AS idx
          FROM public.refill_plan_output r2 JOIN mach m ON m.machine_id = r2.machine_id
          WHERE r2.pod_product_id IS NOT NULL AND r2.max_stock IS NOT NULL AND r2.shelf_code ~ '^A[0-9]{1,2}$') a
    WHERE idx BETWEEN 1 AND 16) r
  UNION ALL
  SELECT v.pod_product_id, v.shelf_size, v.max_stock::numeric FROM (
    SELECT pod_product_id, max_stock,
      CASE WHEN idx BETWEEN 1 AND 8 THEN 'Small' WHEN idx BETWEEN 9 AND 14 THEN 'Medium'
           WHEN idx BETWEEN 15 AND 16 THEN 'Large' END AS shelf_size
    FROM (SELECT vls.pod_product_id, vls.max_stock, NULLIF(regexp_replace(vls.slot_name,'^A0*',''),'')::int AS idx
          FROM public.v_live_shelf_stock vls JOIN mach m ON m.machine_id = vls.machine_id
          WHERE vls.pod_product_id IS NOT NULL AND vls.max_stock IS NOT NULL AND vls.slot_name ~ '^A[0-9]{1,2}$') b
    WHERE idx BETWEEN 1 AND 16) v
),
obs_med AS (SELECT pod_product_id, shelf_size, percentile_cont(0.5) WITHIN GROUP (ORDER BY max_stock) AS med FROM obs GROUP BY 1,2),
fit_keys AS (SELECT pod_product_id, shelf_size FROM occ_agg UNION SELECT pod_product_id, shelf_size FROM cap)
SELECT fk.pod_product_id, fk.shelf_size, true,
  CASE WHEN oa.pod_product_id IS NOT NULL AND c.pod_product_id IS NOT NULL THEN 'both'
       WHEN oa.pod_product_id IS NOT NULL THEN 'history' ELSE 'capacity_standard' END,
  COALESCE(oa.machines_seen,0),
  COALESCE(round(om.med)::int, c.target_cap),
  CASE WHEN COALESCE(round(om.med)::int, c.target_cap) IS NULL THEN NULL
       ELSE ceil(0.70 * COALESCE(round(om.med)::int, c.target_cap))::int END
FROM fit_keys fk
LEFT JOIN occ_agg oa ON oa.pod_product_id=fk.pod_product_id AND oa.shelf_size=fk.shelf_size
LEFT JOIN cap c ON c.pod_product_id=fk.pod_product_id AND c.shelf_size=fk.shelf_size
LEFT JOIN obs_med om ON om.pod_product_id=fk.pod_product_id AND om.shelf_size=fk.shelf_size
JOIN public.pod_products pp ON pp.pod_product_id=fk.pod_product_id
ON CONFLICT (pod_product_id, shelf_size) DO UPDATE
  SET fits=EXCLUDED.fits, fit_basis=EXCLUDED.fit_basis, machines_seen=EXCLUDED.machines_seen,
      cap_typical=EXCLUDED.cap_typical, min_refill_qty=EXCLUDED.min_refill_qty, updated_at=now();
