-- Additive Boonz-tracker access for full-app users (e.g. Raffy as operator_admin)
-- without changing their app role. Flag lives on user_profiles so the (app)
-- layout reads it in its existing SELECT (no extra round-trip).
alter table public.user_profiles
  add column if not exists tracker_boonz_access boolean not null default false;

-- SECURITY DEFINER so RLS policies / triggers can consult it without recursing
-- through user_profiles RLS.
create or replace function public.has_boonz_tracker_access()
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select tracker_boonz_access from public.user_profiles where id = auth.uid()),
    false
  );
$$;
grant execute on function public.has_boonz_tracker_access() to authenticated;

-- Boonz-only read/insert/update for flagged collaborators.
drop policy if exists agenda_items_boonz_collab_select on public.agenda_items;
create policy agenda_items_boonz_collab_select on public.agenda_items
  for select using (category = 'Boonz' and public.has_boonz_tracker_access());

drop policy if exists agenda_items_boonz_collab_insert on public.agenda_items;
create policy agenda_items_boonz_collab_insert on public.agenda_items
  for insert with check (category = 'Boonz' and public.has_boonz_tracker_access());

drop policy if exists agenda_items_boonz_collab_update on public.agenda_items;
create policy agenda_items_boonz_collab_update on public.agenda_items
  for update
  using (category = 'Boonz' and public.has_boonz_tracker_access())
  with check (category = 'Boonz' and public.has_boonz_tracker_access());

-- Extend the column guard: collaborators (like the dormant tracker_boonz role)
-- may only change status + notes.
create or replace function public.agenda_items_tracker_column_guard()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.current_app_role() = 'tracker_boonz'
     or public.has_boonz_tracker_access() then
    if (new.title       is distinct from old.title)
       or (new.category is distinct from old.category)
       or (new.urgency  is distinct from old.urgency)
       or (new.due_date is distinct from old.due_date)
       or (new.sort_order   is distinct from old.sort_order)
       or (new.cross_cutting is distinct from old.cross_cutting)
       or (new.owner_id is distinct from old.owner_id) then
      raise exception 'Boonz tracker collaborators may only edit status and notes';
    end if;
  end if;
  return new;
end $$;

-- Grant Raffy the Boonz-tracker collaborator flag.
update public.user_profiles
  set tracker_boonz_access = true, updated_at = now()
  where id = '38c282e3-7468-4071-99d0-0473e3a4818f';
