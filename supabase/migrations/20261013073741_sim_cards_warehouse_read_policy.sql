-- sim_cards: warehouse and field_staff could open /field/config/sims but RLS only let operator_admin/manager/superadmin read, so the page showed "No SIM cards found". Read-only policy for the field roles; writes stay admin/manager only.
create policy sim_cards_field_read on public.sim_cards
for select to authenticated
using (exists (select 1 from public.user_profiles up where up.id = (select auth.uid()) and up.role in ('warehouse','field_staff')));
