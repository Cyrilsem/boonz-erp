-- PRD-CLEAN-11 M1 (DDL): allow 'gym' as a machine location_type.
-- LevelUp partnership machines are in gyms; previously mislabelled 'warehouse',
-- which put two live selling machines in scope of warehouse-targeted operations.
ALTER TABLE public.machines DROP CONSTRAINT machines_location_type_check;
ALTER TABLE public.machines ADD CONSTRAINT machines_location_type_check
  CHECK (((location_type IS NULL) OR (location_type = ANY (ARRAY[
    'office'::text, 'coworking'::text, 'entertainment'::text, 'warehouse'::text, 'gym'::text
  ]))));
