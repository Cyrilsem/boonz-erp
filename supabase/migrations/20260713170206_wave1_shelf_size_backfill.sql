-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260713170206  name: wave1_shelf_size_backfill
-- WAVE-1 (Cody-approved w/ audit-GUC revision): shelf_configurations.shelf_size backfill.
-- Rule: non-V0 A01-08=Small/A09-14=Medium/A15-16=Large; B mirrored; V0 all Small; C/D/E NULL.
-- Article 8: set audit GUCs so tg_audit_shelf_configurations logs via_rpc=true.
SELECT set_config('app.via_rpc','true',true);
SELECT set_config('app.rpc_name','wave1_shelf_size_backfill',true);

ALTER TABLE public.shelf_configurations ADD COLUMN IF NOT EXISTS shelf_size text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'shelf_configurations_shelf_size_check'
      AND conrelid = 'public.shelf_configurations'::regclass
  ) THEN
    ALTER TABLE public.shelf_configurations
      ADD CONSTRAINT shelf_configurations_shelf_size_check
      CHECK (shelf_size IN ('Small','Medium','Large') OR shelf_size IS NULL);
  END IF;
END $$;

UPDATE public.shelf_configurations sc
SET shelf_size = CASE
    WHEN m.official_name LIKE '%V0'     AND sc.shelf_code LIKE 'A%'                 THEN 'Small'
    WHEN m.official_name NOT LIKE '%V0' AND sc.shelf_code BETWEEN 'A01' AND 'A08'   THEN 'Small'
    WHEN m.official_name NOT LIKE '%V0' AND sc.shelf_code BETWEEN 'A09' AND 'A14'   THEN 'Medium'
    WHEN m.official_name NOT LIKE '%V0' AND sc.shelf_code BETWEEN 'A15' AND 'A16'   THEN 'Large'
    WHEN m.official_name NOT LIKE '%V0' AND sc.shelf_code BETWEEN 'B01' AND 'B08'   THEN 'Small'
    WHEN m.official_name NOT LIKE '%V0' AND sc.shelf_code BETWEEN 'B09' AND 'B14'   THEN 'Medium'
    WHEN m.official_name NOT LIKE '%V0' AND sc.shelf_code BETWEEN 'B15' AND 'B16'   THEN 'Large'
END
FROM public.machines m
WHERE m.machine_id = sc.machine_id
  AND sc.is_phantom = false
  AND (
        (m.official_name LIKE '%V0'     AND sc.shelf_code LIKE 'A%')
     OR (m.official_name NOT LIKE '%V0' AND (sc.shelf_code BETWEEN 'A01' AND 'A16'
                                          OR sc.shelf_code BETWEEN 'B01' AND 'B16')))
  ;
