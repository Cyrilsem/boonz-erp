-- P0 FIX9 (2026-07-12, CS directive): 'Hunter Ridge - Hot N Sweet' belongs to pod
-- 'Hunter Ridge' ONLY. Its 32 active mappings under pod 'Hunter' made the boonz->pod
-- reverse lookup ambiguous (known landmine) and let stitch source Hunter Ridge stock
-- for Hunter shelves. Deactivate (never delete) the wrong-home rows.
UPDATE public.product_mapping pm
   SET status = 'Inactive'
FROM public.pod_products pp, public.boonz_products bp
WHERE pp.pod_product_id = pm.pod_product_id
  AND bp.product_id = pm.boonz_product_id
  AND pp.pod_product_name = 'Hunter'
  AND bp.boonz_product_name ILIKE 'Hunter Ridge%'
  AND pm.status = 'Active';

INSERT INTO public.monitoring_alerts(source, severity, payload)
VALUES ('product_mapping','warning', jsonb_build_object(
  'title','FIX9: deactivated Hunter Ridge mappings under pod Hunter (32 rows) — Hunter Ridge is its own pod. Per CS 2026-07-12.',
  'changed_at', now()));
