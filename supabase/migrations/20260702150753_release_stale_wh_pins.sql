-- Fix: pack_dispatch_line pins whole WH batch remainder to one machine via reserved_for_machine_id
-- and nothing releases it after pickup -> siblings see Available 0 (blocked_no_wh / not_filled).
-- Canonical releaser: clears pins that have no in-transit (packed, not picked up) dispatch line.
create or replace function public.release_stale_wh_pins()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_released int;
begin
  perform set_config('app.via_rpc','true', true);
  perform set_config('app.rpc_name','release_stale_wh_pins', true);
  perform set_config('app.mutation_reason','auto-release stale WH batch pins (no in-transit dispatch line)', true);

  update warehouse_inventory wi
     set reserved_for_machine_id = null
   where wi.reserved_for_machine_id is not null
     and not exists (
       select 1
       from refill_dispatching rd
       where rd.machine_id = wi.reserved_for_machine_id
         and rd.boonz_product_id = wi.boonz_product_id
         and coalesce(rd.packed,false) = true
         and coalesce(rd.picked_up,false) = false
         and coalesce(rd.cancelled,false) = false
     );
  get diagnostics v_released = row_count;

  return jsonb_build_object('status','ok','pins_released',v_released,'at',now());
end;
$$;

revoke all on function public.release_stale_wh_pins() from public;
grant execute on function public.release_stale_wh_pins() to service_role;

-- pg_cron job 34: hourly at :50. Already live in prod (created alongside the fn via MCP);
-- recorded here for git truth. unschedule-first keeps this re-runnable on fresh envs.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'release-stale-wh-pins') then
    perform cron.unschedule('release-stale-wh-pins');
  end if;
  perform cron.schedule('release-stale-wh-pins', '50 * * * *', 'select public.release_stale_wh_pins()');
end $$;
