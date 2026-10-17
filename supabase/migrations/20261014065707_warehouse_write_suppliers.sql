-- 14 Oct 2026: CS decision. Warehouse (Simran) must be able to add and edit
-- suppliers from /field/config/suppliers. PRD-139b item 4 had removed all
-- warehouse write on suppliers; this restores INSERT and UPDATE only.
-- DELETE stays admins-only (admins_manage_suppliers). The item 4 column
-- grants that hide bank_details and payment_terms from non-admin SELECT are
-- untouched.

create policy warehouse_insert_suppliers on public.suppliers
  for insert to authenticated
  with check (exists (
    select 1 from public.user_profiles
    where user_profiles.id = (select auth.uid())
      and user_profiles.role = 'warehouse'
  ));

create policy warehouse_update_suppliers on public.suppliers
  for update to authenticated
  using (exists (
    select 1 from public.user_profiles
    where user_profiles.id = (select auth.uid())
      and user_profiles.role = 'warehouse'
  ))
  with check (exists (
    select 1 from public.user_profiles
    where user_profiles.id = (select auth.uid())
      and user_profiles.role = 'warehouse'
  ));
