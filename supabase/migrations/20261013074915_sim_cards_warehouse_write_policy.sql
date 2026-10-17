-- sim_cards: warehouse role can now add and edit SIM rows (assign/unassign, PUK, numbers). Delete stays admin/manager. Every change is captured by the existing tg_audit_sim_cards trigger (audit_log_write) with the acting user.
create policy sim_cards_warehouse_insert on public.sim_cards
for insert to authenticated
with check (exists (select 1 from public.user_profiles up where up.id = (select auth.uid()) and up.role = 'warehouse'));

create policy sim_cards_warehouse_update on public.sim_cards
for update to authenticated
using (exists (select 1 from public.user_profiles up where up.id = (select auth.uid()) and up.role = 'warehouse'))
with check (exists (select 1 from public.user_profiles up where up.id = (select auth.uid()) and up.role = 'warehouse'));
