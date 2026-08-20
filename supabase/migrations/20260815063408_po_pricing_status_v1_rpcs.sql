-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Part 1/4 of the 2026-08-15 pricing_status rollout (see 20260815092204_po_pricing_status_v1.sql,
-- the annotated single-file form / source of truth for all four parts).
-- create_po_addition_v2: dropped at 7 args, recreated at 8 with p_pricing_status.
-- New review_price_flag_v1. Anon EXECUTE revoked on the three PRD-022 write RPCs.

drop function if exists public.create_po_addition_v2(text, uuid, numeric, numeric, date, text, text);

create or replace function public.create_po_addition_v2(
  p_po_id             text,
  p_boonz_product_id  uuid,
  p_qty               numeric,
  p_total_price_aed   numeric,
  p_expiry_date       date    default null,
  p_wh_location       text    default null,
  p_notes             text    default null,
  p_pricing_status    text    default 'priced'
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_role  text;
  v_id    uuid;
  v_unit  numeric;
  v_flag  jsonb;
  v_stat  text := coalesce(nullif(trim(p_pricing_status), ''), 'priced');
  v_total numeric := coalesce(p_total_price_aed, 0);
begin
  perform public.set_write_context(
    'create_po_addition_v2',
    format('field addition of %s units to %s (total %s AED, %s)',
           p_qty, p_po_id, p_total_price_aed, v_stat),
    'po_receive', p_po_id);

  select role into v_role from public.user_profiles where id = v_actor;
  if coalesce(v_role, '') not in
     ('field_staff', 'warehouse', 'operator_admin', 'superadmin', 'manager') then
    return jsonb_build_object('status', 'error', 'error', 'Insufficient role');
  end if;

  if p_po_id is null or p_boonz_product_id is null or coalesce(p_qty, 0) <= 0 then
    return jsonb_build_object('status', 'error',
      'error', 'p_po_id, p_boonz_product_id and a positive p_qty are required');
  end if;
  if p_total_price_aed is not null and p_total_price_aed < 0 then
    return jsonb_build_object('status', 'error', 'error', 'p_total_price_aed cannot be negative');
  end if;

  if v_stat not in ('priced', 'free_goods') then
    return jsonb_build_object('status', 'error',
      'error', 'p_pricing_status must be priced or free_goods',
      'error_code', 'BAD_PRICING_STATUS',
      'pricing_status', v_stat);
  end if;
  if v_stat = 'free_goods' and v_total <> 0 then
    return jsonb_build_object('status', 'error',
      'error', 'free_goods requires an empty or zero p_total_price_aed',
      'error_code', 'FREE_GOODS_WITH_PRICE',
      'total_price_aed', p_total_price_aed);
  end if;
  if v_stat = 'priced' and v_total <= 0 then
    return jsonb_build_object('status', 'error',
      'error', 'a priced addition needs a positive total; tick free goods if 0.00 is correct',
      'error_code', 'PRICED_WITHOUT_TOTAL',
      'total_price_aed', p_total_price_aed);
  end if;

  insert into public.po_additions (
    po_id, boonz_product_id, qty, total_price_aed,
    added_by, expiry_date, wh_location, notes, pricing_status
  ) values (
    p_po_id, p_boonz_product_id, p_qty, p_total_price_aed,
    v_actor, p_expiry_date, p_wh_location, p_notes, v_stat
  )
  returning addition_id, price_per_unit_aed, price_flag
       into v_id, v_unit, v_flag;

  insert into public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) values (
    'po_additions', 'INSERT', v_id::text, v_actor, v_role, true, 'create_po_addition_v2',
    jsonb_build_object('po_id', p_po_id, 'qty', p_qty,
                       'total_price_aed', p_total_price_aed,
                       'derived_unit_aed', v_unit,
                       'pricing_status', v_stat,
                       'price_flag', v_flag)
  );

  return jsonb_build_object(
    'status',           'ok',
    'addition_id',      v_id,
    'qty',              p_qty,
    'total_price_aed',  p_total_price_aed,
    'derived_unit_aed', v_unit,
    'pricing_status',   v_stat,
    'price_flag',       v_flag
  );
end;
$function$;

revoke all on function public.create_po_addition_v2(text, uuid, numeric, numeric, date, text, text, text) from public, anon;
grant execute on function public.create_po_addition_v2(text, uuid, numeric, numeric, date, text, text, text) to authenticated, service_role;

revoke all on function public.correct_procurement_unit_price_v1(text, uuid, numeric, text, boolean) from public, anon;
grant execute on function public.correct_procurement_unit_price_v1(text, uuid, numeric, text, boolean) to authenticated, service_role;

revoke all on function public.receive_purchase_order_addition(uuid, uuid, date, text) from public, anon;
grant execute on function public.receive_purchase_order_addition(uuid, uuid, date, text) to authenticated, service_role;

create or replace function public.review_price_flag_v1(
  p_table   text,
  p_row_id  uuid,
  p_verdict text,
  p_note    text
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_role  text;
  v_flag  jsonb;
  v_po    text;
  v_stat  text;
  v_code  text;
begin
  select role into v_role from public.user_profiles where id = v_actor;
  if coalesce(v_role, '') not in ('operator_admin', 'superadmin', 'manager') then
    return jsonb_build_object('status', 'error', 'error', 'Insufficient role');
  end if;
  if p_table not in ('po_additions', 'purchase_orders') then
    return jsonb_build_object('status', 'error',
      'error', 'p_table must be po_additions or purchase_orders');
  end if;
  if coalesce(p_verdict, '') not in ('confirmed_correct', 'corrected') then
    return jsonb_build_object('status', 'error',
      'error', 'p_verdict must be confirmed_correct or corrected');
  end if;
  if length(coalesce(trim(p_note), '')) < 10 then
    return jsonb_build_object('status', 'error',
      'error', 'p_note is required and must be at least 10 characters');
  end if;

  perform public.set_write_context('review_price_flag_v1', p_note,
                                   'price_flag_review', p_row_id::text);

  if p_table = 'po_additions' then
    select price_flag, po_id, pricing_status into v_flag, v_po, v_stat
      from public.po_additions where addition_id = p_row_id for update;
    if not found then
      return jsonb_build_object('status', 'error', 'error', 'Row not found');
    end if;
    if v_flag is null then
      return jsonb_build_object('status', 'error', 'error', 'Row carries no price flag');
    end if;
    update public.po_additions set price_flag = null where addition_id = p_row_id;
  else
    select price_flag, po_id, pricing_status into v_flag, v_po, v_stat
      from public.purchase_orders where po_line_id = p_row_id for update;
    if not found then
      return jsonb_build_object('status', 'error', 'error', 'Row not found');
    end if;
    if v_flag is null then
      return jsonb_build_object('status', 'error', 'error', 'Row carries no price flag');
    end if;
    update public.purchase_orders
       set price_flag     = null,
           last_edited_at = now(),
           last_edited_by = v_actor
     where po_line_id = p_row_id;
  end if;

  v_code := v_flag ->> 'code';

  insert into public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) values (
    p_table, 'UPDATE', p_row_id::text, v_actor, v_role, true, 'review_price_flag_v1',
    jsonb_build_object('event', 'price_flag_reviewed',
                       'verdict', p_verdict, 'note', p_note,
                       'flag_code', v_code, 'pricing_status', v_stat,
                       'cleared_flag', v_flag)
  );

  insert into public.procurement_events (po_id, event_type, performed_by, payload)
  values (v_po, 'price_flag_reviewed', v_actor,
    jsonb_build_object('table', p_table, 'row_id', p_row_id,
                       'verdict', p_verdict, 'note', p_note,
                       'flag_code', v_code, 'pricing_status', v_stat,
                       'cleared_flag', v_flag));

  perform set_config('app.via_rpc', 'false', true);

  return jsonb_build_object(
    'status',            'ok',
    'table',             p_table,
    'row_id',            p_row_id,
    'verdict',           p_verdict,
    'cleared_flag_code', v_code,
    'pricing_status',    v_stat
  );
end;
$function$;

revoke all on function public.review_price_flag_v1(text, uuid, text, text) from public, anon;
grant execute on function public.review_price_flag_v1(text, uuid, text, text) to authenticated, service_role;
