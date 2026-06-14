-- PRD-030 step 3a-fix: audit_log_write() addresses rows by `.id`. Add a surrogate id PK;
-- keep (machine_id, dispatch_date) unique as the upsert key. Forward-only (table new+empty).
ALTER TABLE public.dispatch_pack_confirmation ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.dispatch_pack_confirmation DROP CONSTRAINT IF EXISTS dispatch_pack_confirmation_pkey;
ALTER TABLE public.dispatch_pack_confirmation ADD PRIMARY KEY (id);
ALTER TABLE public.dispatch_pack_confirmation DROP CONSTRAINT IF EXISTS dispatch_pack_confirmation_machine_date_uniq;
ALTER TABLE public.dispatch_pack_confirmation ADD CONSTRAINT dispatch_pack_confirmation_machine_date_uniq UNIQUE (machine_id, dispatch_date);
