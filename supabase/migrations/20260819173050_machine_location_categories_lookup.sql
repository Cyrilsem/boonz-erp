-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- New lookup table for machine section grouping in /app/pods and /field/config/machines (was
-- hardcoded FE buckets; adding a market previously required a deploy).

create table if not exists public.machine_location_categories (
  code                  text primary key,
  label                 text not null,
  hint                  text,
  sort_order            integer not null,
  wins_over_active      boolean not null default false,
  collapsed_by_default  boolean not null default false,
  assignable            boolean not null default true,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now()
);

alter table public.machines
  add column if not exists location_category text references public.machine_location_categories(code);

create index if not exists idx_machines_location_category
  on public.machines (location_category);

alter table public.machine_location_categories enable row level security;

drop policy if exists mlc_read on public.machine_location_categories;
create policy mlc_read on public.machine_location_categories
  for select
  to authenticated
  using (true);

drop policy if exists mlc_admin_write on public.machine_location_categories;
create policy mlc_admin_write on public.machine_location_categories
  for all
  to authenticated
  using (exists (
    select 1 from public.user_profiles
    where user_profiles.id = (select auth.uid())
      and user_profiles.role = any (array['operator_admin', 'superadmin', 'manager'])
  ))
  with check (exists (
    select 1 from public.user_profiles
    where user_profiles.id = (select auth.uid())
      and user_profiles.role = any (array['operator_admin', 'superadmin', 'manager'])
  ));

insert into public.machine_location_categories
  (code, label, hint, sort_order, wins_over_active, collapsed_by_default, assignable, is_active)
values
  ('in_market', 'In Market',              'installed & selling',              0,  false, false, false, true),
  ('office',    'Office / Central',       'stored at the office',             10, false, false, true,  true),
  ('dip',       'DIP Warehouse',          'stored in DIP',                    20, false, false, true,  true),
  ('china',     'China',                  'not yet shipped',                  30, false, true,  true,  true),
  ('lebanon',   'Lebanon',                'Lebanon market — active or staged', 40, true,  false, true,  true),
  ('legacy',    'Legacy (records only)',  'records only — not counted',       50, true,  true,  true,  true),
  ('other',     'Other Inactive',         'unclassified',                     60, false, false, false, true)
on conflict (code) do nothing;

-- Body NOT recoverable: the one-time backfill of machines.location_category from pod_location
-- (Legacy/Lebanon/Office/Central/DIP/China -> legacy/lebanon/office/office/dip/china; 65 rows
-- categorized) was a one-off data mutation done the same day via execute_sql.
-- intentionally empty: data fix already applied to prod 20260819173050 -- the current
-- machines.location_category values are indistinguishable from a manually assigned category, so
-- there is no separate current-state trace to replay this as an idempotent statement.
