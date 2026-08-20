-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-022 total-first pricing + advisory flagger. Trigger, helpers, RPCs and view reconstructed as
-- their 2026-08-14 originals by subtracting the pricing_status additions that supabase/migrations/
-- 20260815092204_po_pricing_status_v1.sql documents adding on top of this migration (that later file
-- is NOT touched/duplicated here; it is read only as a diff reference). procurement_price_sync_and_flag
-- and v_po_price_flags are mechanically recovered (that file states the trigger's non-pricing_status
-- body is byte-identical and the view's pricing_status column was APPENDED last). create_po_addition_v2
-- is an inferred original (the later migration DROPs+recreates it rather than diffing it) - not a
-- byte-exact recovery. Backfill note (not reproduced, one-off data fix): 14 existing rows were stamped
-- with price_flag->>'backfilled' = 'true' at original apply time.

-- 1. Columns ------------------------------------------------------------------
ALTER TABLE public.po_additions
  ADD COLUMN IF NOT EXISTS total_price_aed numeric,
  ADD COLUMN IF NOT EXISTS price_flag jsonb;

ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS total_price_aed numeric,
  ADD COLUMN IF NOT EXISTS price_flag jsonb;

-- 2. Helpers --------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.price_looks_like_line_total_v1(p_qty numeric, p_unit numeric, p_median numeric, p_n_obs integer)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(
    p_qty    >  1
    and p_unit   >  0
    and p_n_obs  >= 2
    and p_median >  0
    and p_unit   >  2.0 * p_median
    and abs((p_unit / p_qty) - p_median) <= 0.35 * p_median
  , false);
$function$;

CREATE OR REPLACE FUNCTION public.classify_procurement_price_v1(p_qty numeric, p_unit numeric, p_median numeric, p_n_obs integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_unit is null or p_unit <= 0
      or coalesce(p_median, 0) <= 0
      or coalesce(p_n_obs, 0) < 2                                  then null
    when public.price_looks_like_line_total_v1(p_qty, p_unit, p_median, p_n_obs)
                                                                   then 'LOOKS_LIKE_LINE_TOTAL'
    when p_unit > 2.0  * p_median                                  then 'PRICE_HIGH'
    when p_unit < 0.10 * p_median                                  then 'PRICE_LOW'
    else null
  end;
$function$;

CREATE OR REPLACE FUNCTION public.peer_unit_price_v1(p_boonz_product_id uuid, p_exclude_row text DEFAULT NULL::text)
 RETURNS TABLE(median_unit_aed numeric, n_obs integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with obs as (
    select po_line_id::text as row_id, price_per_unit_aed::numeric as unit
    from public.purchase_orders
    where boonz_product_id = p_boonz_product_id
      and price_per_unit_aed > 0
      and coalesce(nullif(received_qty, 0), ordered_qty) > 0
    union all
    select addition_id::text, price_per_unit_aed::numeric
    from public.po_additions
    where boonz_product_id = p_boonz_product_id
      and price_per_unit_aed > 0
      and qty > 0
  ),
  kept as (
    select unit from obs
    where p_exclude_row is null or row_id is distinct from p_exclude_row
  )
  select (percentile_cont(0.5) within group (order by unit))::numeric,
         count(*)::integer
  from kept;
$function$;

-- 3. Trigger fn: total<->unit sync + peer-price classification -----------------
-- Reconstructed by removing the "PRD-022 pricing_status" block that
-- 20260815092204_po_pricing_status_v1.sql inserts on top of this body (that
-- migration states the rest is byte-identical). No pricing_status reference:
-- the column does not exist yet at this point in history.

CREATE OR REPLACE FUNCTION public.procurement_price_sync_and_flag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_qty       numeric;
  v_unit      numeric;
  v_product   uuid;
  v_rowid     text;
  v_med       numeric;
  v_n         integer;
  v_code      text;
  v_prev_code text;
  v_changed   boolean;
begin
  if tg_table_name = 'po_additions' then
    v_qty := new.qty;

    if tg_op = 'INSERT' then
      if new.total_price_aed is not null and coalesce(v_qty, 0) > 0 then
        new.price_per_unit_aed := round(new.total_price_aed / v_qty, 4);
      elsif new.price_per_unit_aed is not null and coalesce(v_qty, 0) > 0 then
        new.total_price_aed := round(v_qty * new.price_per_unit_aed, 2);
      end if;
      v_changed := true;
    else
      if new.total_price_aed is distinct from old.total_price_aed
         and new.total_price_aed is not null and coalesce(v_qty, 0) > 0 then
        new.price_per_unit_aed := round(new.total_price_aed / v_qty, 4);
      elsif new.price_per_unit_aed is distinct from old.price_per_unit_aed
         and new.price_per_unit_aed is not null and coalesce(v_qty, 0) > 0 then
        new.total_price_aed := round(v_qty * new.price_per_unit_aed, 2);
      elsif new.qty is distinct from old.qty
         and new.total_price_aed is not null and coalesce(v_qty, 0) > 0 then
        new.price_per_unit_aed := round(new.total_price_aed / v_qty, 4);
      end if;
      v_changed := new.price_per_unit_aed is distinct from old.price_per_unit_aed
                or new.total_price_aed    is distinct from old.total_price_aed
                or new.qty                is distinct from old.qty;
      v_prev_code := old.price_flag ->> 'code';
    end if;

    v_unit    := new.price_per_unit_aed;
    v_product := new.boonz_product_id;
    v_rowid   := new.addition_id::text;

  else
    v_qty := coalesce(nullif(new.received_qty, 0), new.ordered_qty);

    if tg_op = 'INSERT' then
      if new.total_price_aed is not null and new.price_per_unit_aed is null
         and coalesce(v_qty, 0) > 0 then
        new.price_per_unit_aed := round(new.total_price_aed / v_qty, 4);
      elsif new.price_per_unit_aed is not null and new.total_price_aed is null
         and coalesce(v_qty, 0) > 0 then
        new.total_price_aed := round(v_qty * new.price_per_unit_aed, 2);
      end if;
      v_changed := true;
    else
      if new.total_price_aed is distinct from old.total_price_aed
         and new.price_per_unit_aed is not distinct from old.price_per_unit_aed
         and new.total_price_aed is not null and coalesce(v_qty, 0) > 0 then
        new.price_per_unit_aed := round(new.total_price_aed / v_qty, 4);
      elsif new.price_per_unit_aed is distinct from old.price_per_unit_aed
         and new.total_price_aed is not distinct from old.total_price_aed
         and new.price_per_unit_aed is not null and coalesce(v_qty, 0) > 0 then
        new.total_price_aed := round(v_qty * new.price_per_unit_aed, 2);
      end if;
      v_changed := new.price_per_unit_aed is distinct from old.price_per_unit_aed
                or new.total_price_aed    is distinct from old.total_price_aed
                or new.ordered_qty        is distinct from old.ordered_qty
                or new.received_qty       is distinct from old.received_qty;
      v_prev_code := old.price_flag ->> 'code';
    end if;

    v_unit    := new.price_per_unit_aed;
    v_product := new.boonz_product_id;
    v_rowid   := new.po_line_id::text;
  end if;

  if not v_changed then
    return new;
  end if;

  if v_unit is null or v_unit <= 0 or coalesce(v_qty, 0) <= 0 or v_product is null then
    new.price_flag := null;
    return new;
  end if;

  select median_unit_aed, n_obs
    into v_med, v_n
    from public.peer_unit_price_v1(v_product, v_rowid);

  v_code := public.classify_procurement_price_v1(v_qty, v_unit, v_med, v_n);

  if v_code is null then
    new.price_flag := null;
    return new;
  end if;

  new.price_flag := jsonb_build_object(
    'code',                  v_code,
    'unit_aed',              round(v_unit, 4),
    'total_aed',             new.total_price_aed,
    'qty',                   v_qty,
    'peer_median_unit_aed',  round(v_med, 4),
    'peer_observations',     v_n,
    'unit_vs_median_pct',    round(100 * v_unit / v_med, 1),
    'suggested_unit_aed',    case when v_code = 'LOOKS_LIKE_LINE_TOTAL'
                                  then round(v_unit / v_qty, 4) end,
    'flagged_at',            now()
  );

  if v_prev_code is distinct from v_code then
    insert into public.procurement_events (po_id, event_type, performed_by, payload)
    values (new.po_id, 'price_flag_raised', auth.uid(),
            new.price_flag || jsonb_build_object('table', tg_table_name, 'row_id', v_rowid));
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE TRIGGER trg_price_sync_flag_po_additions
  BEFORE INSERT OR UPDATE ON public.po_additions
  FOR EACH ROW EXECUTE FUNCTION public.procurement_price_sync_and_flag();

CREATE OR REPLACE TRIGGER trg_price_sync_flag_purchase_orders
  BEFORE INSERT OR UPDATE ON public.purchase_orders
  FOR EACH ROW EXECUTE FUNCTION public.procurement_price_sync_and_flag();

-- 4. create_po_addition_v2 (7-arg original, no p_pricing_status) ----------------
-- INFERRED reconstruction: 20260815092204 DROPs and recreates this function
-- rather than diffing it, so the exact original wording is not recoverable.
-- Reconstructed by removing the pricing_status/free_goods contract that file adds.

CREATE OR REPLACE FUNCTION public.create_po_addition_v2(
  p_po_id             text,
  p_boonz_product_id  uuid,
  p_qty               numeric,
  p_total_price_aed   numeric,
  p_expiry_date       date    default null,
  p_wh_location       text    default null,
  p_notes             text    default null
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := (select auth.uid());
  v_role  text;
  v_id    uuid;
  v_unit  numeric;
  v_flag  jsonb;
begin
  perform public.set_write_context(
    'create_po_addition_v2',
    format('field addition of %s units to %s (total %s AED)', p_qty, p_po_id, p_total_price_aed),
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
  if coalesce(p_total_price_aed, 0) <= 0 then
    return jsonb_build_object('status', 'error', 'error', 'p_total_price_aed must be positive');
  end if;

  insert into public.po_additions (
    po_id, boonz_product_id, qty, total_price_aed,
    added_by, expiry_date, wh_location, notes
  ) values (
    p_po_id, p_boonz_product_id, p_qty, p_total_price_aed,
    v_actor, p_expiry_date, p_wh_location, p_notes
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
                       'price_flag', v_flag)
  );

  return jsonb_build_object(
    'status',           'ok',
    'addition_id',      v_id,
    'qty',              p_qty,
    'total_price_aed',  p_total_price_aed,
    'derived_unit_aed', v_unit,
    'price_flag',       v_flag
  );
end;
$function$;

REVOKE ALL ON FUNCTION public.create_po_addition_v2(text, uuid, numeric, numeric, date, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_po_addition_v2(text, uuid, numeric, numeric, date, text, text) TO authenticated, service_role;

-- 5. correct_procurement_unit_price_v1 (untouched by the 08-15 migration) ------

CREATE OR REPLACE FUNCTION public.correct_procurement_unit_price_v1(p_table text, p_row_id uuid, p_new_unit numeric, p_reason text, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_role  text;
  v_old   numeric;
  v_qty   numeric;
  v_note  text;
begin
  select role into v_role from public.user_profiles where id = v_actor;
  if coalesce(v_role, '') not in ('operator_admin', 'superadmin', 'manager') then
    return jsonb_build_object('status', 'error', 'error', 'Insufficient role');
  end if;
  if p_table not in ('po_additions', 'purchase_orders') then
    return jsonb_build_object('status', 'error', 'error', 'p_table must be po_additions or purchase_orders');
  end if;
  if coalesce(p_new_unit, 0) <= 0 or coalesce(trim(p_reason), '') = '' then
    return jsonb_build_object('status', 'error', 'error', 'p_new_unit and p_reason are required');
  end if;

  perform public.set_write_context('correct_procurement_unit_price_v1', p_reason,
                                   'price_correction', p_row_id::text);
  perform set_config('app.price_override_reason', 'correction: ' || p_reason, true);

  if p_table = 'po_additions' then
    select price_per_unit_aed, qty into v_old, v_qty
      from public.po_additions where addition_id = p_row_id for update;
    if not found then
      return jsonb_build_object('status', 'error', 'error', 'Row not found');
    end if;
    v_note := 'Corrected ' || to_char(current_date, 'YYYY-MM-DD')
           || ': unit price ' || v_old::text || ' -> ' || p_new_unit::text
           || ' AED. ' || p_reason;
    if not p_dry_run then
      update public.po_additions
         set price_per_unit_aed = p_new_unit,
             notes = coalesce(notes || ' | ', '') || v_note
       where addition_id = p_row_id;
    end if;
  else
    select price_per_unit_aed, coalesce(nullif(received_qty, 0), ordered_qty)
      into v_old, v_qty
      from public.purchase_orders where po_line_id = p_row_id for update;
    if not found then
      return jsonb_build_object('status', 'error', 'error', 'Row not found');
    end if;
    if not p_dry_run then
      update public.purchase_orders
         set price_per_unit_aed = p_new_unit,
             total_price_aed    = round(v_qty * p_new_unit, 2),
             last_edited_at     = now(),
             last_edited_by     = v_actor
       where po_line_id = p_row_id;
    end if;
  end if;

  if not p_dry_run then
    insert into public.write_audit_log (
      table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
    ) values (
      p_table, 'UPDATE', p_row_id::text, v_actor, v_role, true,
      'correct_procurement_unit_price_v1',
      jsonb_build_object('event', 'unit_price_corrected',
                         'old_unit_aed', v_old, 'new_unit_aed', p_new_unit,
                         'qty', v_qty,
                         'old_line_total_aed', round(v_qty * v_old, 2),
                         'new_line_total_aed', round(v_qty * p_new_unit, 2),
                         'reason', p_reason)
    );
  end if;

  perform set_config('app.price_override_reason', '', true);

  return jsonb_build_object(
    'status',             case when p_dry_run then 'dry_run' else 'ok' end,
    'table',              p_table,
    'row_id',             p_row_id,
    'qty',                v_qty,
    'old_unit_aed',       v_old,
    'new_unit_aed',       p_new_unit,
    'old_line_total_aed', round(v_qty * v_old, 2),
    'new_line_total_aed', round(v_qty * p_new_unit, 2),
    'delta_aed',          round(v_qty * (p_new_unit - v_old), 2)
  );
end;
$function$;

REVOKE ALL ON FUNCTION public.correct_procurement_unit_price_v1(text, uuid, numeric, text, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.correct_procurement_unit_price_v1(text, uuid, numeric, text, boolean) TO authenticated, service_role;

-- 6. v_po_price_flags (original, pricing_status column not yet added) ----------
-- 20260815092204 states pricing_status was APPENDED as the view's last column
-- via CREATE OR REPLACE VIEW, so the original is the current view minus that
-- trailing column.

CREATE OR REPLACE VIEW public.v_po_price_flags AS
 SELECT 'po_additions'::text AS source_table,
    a.addition_id::text AS row_id,
    a.po_id,
    bp.boonz_product_name,
    a.created_at::date AS row_date,
    a.qty,
    a.price_per_unit_aed AS unit_aed,
    a.total_price_aed AS total_aed,
    a.status,
    a.price_flag ->> 'code'::text AS flag_code,
    a.price_flag
   FROM po_additions a
     JOIN boonz_products bp ON bp.product_id = a.boonz_product_id
  WHERE a.price_flag IS NOT NULL
UNION ALL
 SELECT 'purchase_orders'::text AS source_table,
    po.po_line_id::text AS row_id,
    po.po_id,
    bp.boonz_product_name,
    po.purchase_date AS row_date,
    COALESCE(NULLIF(po.received_qty, 0::numeric), po.ordered_qty) AS qty,
    po.price_per_unit_aed AS unit_aed,
    po.total_price_aed AS total_aed,
    po.purchase_outcome AS status,
    po.price_flag ->> 'code'::text AS flag_code,
    po.price_flag
   FROM purchase_orders po
     JOIN boonz_products bp ON bp.product_id = po.boonz_product_id
  WHERE po.price_flag IS NOT NULL;
