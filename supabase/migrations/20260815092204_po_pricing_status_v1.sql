-- PRD-022 — PO price entry: total-first everywhere, checks, full logging
-- Migration 1 of 3: po_pricing_status_v1
--
-- Builds on the four 2026-08-14 migrations already live in prod:
--   po_unit_price_guard, po_unit_price_guard_fix_record_fields,
--   po_price_total_first_flag_only, procurement_events_allow_price_flag_raised
-- which delivered total_price_aed + price_flag on po_additions and purchase_orders,
-- the procurement_price_sync_and_flag trigger (LOOKS_LIKE_LINE_TOTAL / PRICE_HIGH /
-- PRICE_LOW), create_po_addition_v2, correct_procurement_unit_price_v1,
-- peer_unit_price_v1, classify_procurement_price_v1 and v_po_price_flags.
--
-- This migration adds the missing third state. Today a receipt with no money on it
-- is indistinguishable from a receipt that was genuinely free: both are total = 0,
-- both are unflagged, and the flagger deliberately skips them (a zero unit price
-- cannot be compared to a peer median). pricing_status makes the distinction
-- explicit and lets the flagger say so.
--
-- Constitution notes:
--   * Nothing here blocks a warehouse write. UNPRICED_RECEIPT is advisory, forever.
--     The only writes that can be refused are create_po_addition_v2 argument
--     violations, which return structured jsonb and never RAISE.
--   * purchase_orders qty edits still never rescale prices — the purchase_orders
--     branch of the trigger has no qty-derivation clause and this migration does
--     not add one.
--   * warehouse_inventory.status is untouched.
--   * Forward-only. create_po_addition_v2 is dropped and recreated rather than
--     overloaded, per the CLAUDE.md pg_proc foot-gun rule: CREATE OR REPLACE
--     cannot add a parameter, so replacing it would silently leave two live
--     signatures behind.

-- No explicit begin/commit: apply_migration wraps the body in a transaction of
-- its own, and an inner COMMIT would end that wrapper early (Cody, Article 12).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. pricing_status
-- ─────────────────────────────────────────────────────────────────────────────
-- 'priced'      — money was recorded for this line (the normal case)
-- 'free_goods'  — 0.00 is the truth; a human asserted it. Never flagged.
-- 'unpriced'    — goods landed with no money recorded. System-assigned only.
--
-- Constant default, so no table rewrite on either table.

alter table public.po_additions
  add column if not exists pricing_status text not null default 'priced';

alter table public.purchase_orders
  add column if not exists pricing_status text not null default 'priced';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'po_additions_pricing_status_check') then
    alter table public.po_additions
      add constraint po_additions_pricing_status_check
      check (pricing_status in ('priced', 'free_goods', 'unpriced'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'purchase_orders_pricing_status_check') then
    alter table public.purchase_orders
      add constraint purchase_orders_pricing_status_check
      check (pricing_status in ('priced', 'free_goods', 'unpriced'));
  end if;
end $$;

comment on column public.po_additions.pricing_status is
  'PRD-022. priced | free_goods | unpriced. free_goods is a human assertion that 0.00 is correct and suppresses all price flagging. unpriced is system-assigned by procurement_price_sync_and_flag on a receive with no money and is advisory only.';
comment on column public.purchase_orders.pricing_status is
  'PRD-022. priced | free_goods | unpriced. See po_additions.pricing_status.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. procurement_events: allow the review event
-- ─────────────────────────────────────────────────────────────────────────────
-- UNPRICED_RECEIPT itself is raised as 'price_flag_raised', already allowed.

alter table public.procurement_events
  drop constraint if exists procurement_events_event_type_check;

alter table public.procurement_events
  add constraint procurement_events_event_type_check
  check (event_type = any (array[
    'po_created', 'po_line_edited', 'lines_appended', 'task_assigned',
    'task_acknowledged', 'task_collected', 'task_cancelled', 'task_pending',
    'task_reopened', 'goods_received', 'line_not_purchased',
    'spot_purchase_created', 'spot_purchase_task_autoclosed',
    'post_facto_fill_recorded', 'post_facto_fill_received',
    'po_totals_set', 'po_totals_edited', 'po_addition_line_mirrored',
    'price_flag_raised', 'price_flag_reviewed'
  ]));

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. procurement_price_sync_and_flag — teach it the third state
-- ─────────────────────────────────────────────────────────────────────────────
-- Unchanged from the live body except for the pricing_status block marked
-- PRD-022 below. The total-first sync arithmetic is byte-identical.
--
-- Ordering inside the new block matters and is load-bearing:
--   a. free_goods short-circuits first — a deliberate 0.00 is never flagged and
--      never becomes 'unpriced', whatever else this write did.
--   b. repricing (total > 0 on an unpriced row) returns the row to 'priced' and
--      drops UNPRICED_RECEIPT, then falls through so the repriced number still
--      gets classified — a corrected price can absolutely still be PRICE_HIGH.
--   c. the unpriced stamp fires on the receive transition, or on any later write
--      to a row that is ALREADY carrying UNPRICED_RECEIPT. It deliberately does
--      not fire on a row whose flag was cleared by review_price_flag_v1: that is
--      what stops a reviewed flag resurrecting on the next unrelated edit.
--   d. the stamp is skipped when the code is unchanged, so flagged_at and any
--      extra keys (e.g. backfilled) survive, and the event is emitted once.
--
-- All three exits sit BEFORE the `if not v_changed` early return, because a
-- receive transition is a status change and moves neither price nor qty.

create or replace function public.procurement_price_sync_and_flag()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
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
  v_recv      boolean := false;   -- PRD-022: this write is the receive transition
  v_total     numeric;            -- PRD-022: coalesced line total
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
      v_recv    := new.status = 'received';
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
      v_recv      := new.status = 'received' and old.status is distinct from 'received';
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
      v_recv    := new.purchase_outcome = 'received';
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
      -- 'not_purchased' is a close, not a receipt. It must never become unpriced.
      v_recv      := new.purchase_outcome = 'received'
                 and old.purchase_outcome is distinct from 'received';
    end if;

    v_unit    := new.price_per_unit_aed;
    v_product := new.boonz_product_id;
    v_rowid   := new.po_line_id::text;
  end if;

  -- ── PRD-022 pricing_status ────────────────────────────────────────────────
  v_total := coalesce(new.total_price_aed, 0);

  -- (a) A deliberate 0.00 is the truth. Never flagged, never unpriced.
  if new.pricing_status = 'free_goods' then
    new.price_flag := null;
    return new;
  end if;

  -- (b) Repricing puts an unpriced row back in the priced world, then falls
  --     through so the new number is still classified on its merits.
  if new.pricing_status = 'unpriced' and v_total > 0 then
    new.pricing_status := 'priced';
    if v_prev_code = 'UNPRICED_RECEIPT' then
      new.price_flag := null;
    end if;
  end if;

  -- (c) Goods landed with no money on them. Advisory, never blocking.
  if v_total = 0 and (v_recv or v_prev_code = 'UNPRICED_RECEIPT') then
    new.pricing_status := 'unpriced';

    if v_prev_code is distinct from 'UNPRICED_RECEIPT' then
      new.price_flag := jsonb_build_object(
        'code',                 'UNPRICED_RECEIPT',
        'unit_aed',             new.price_per_unit_aed,
        'total_aed',            new.total_price_aed,
        'qty',                  v_qty,
        'peer_median_unit_aed', null,
        'peer_observations',    null,
        'unit_vs_median_pct',   null,
        'suggested_unit_aed',   null,
        'flagged_at',           now()
      );

      insert into public.procurement_events (po_id, event_type, performed_by, payload)
      values (new.po_id, 'price_flag_raised', auth.uid(),
              new.price_flag || jsonb_build_object('table', tg_table_name, 'row_id', v_rowid));
    end if;

    return new;
  end if;
  -- ── end PRD-022 ───────────────────────────────────────────────────────────

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

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. create_po_addition_v2 — p_pricing_status
-- ─────────────────────────────────────────────────────────────────────────────
-- Dropped and recreated, not replaced: CREATE OR REPLACE cannot add a parameter,
-- so replacing would leave the 7-arg signature live alongside the 8-arg one and
-- PostgREST would resolve either depending on which keys the caller sent. There
-- are no callers today (verified: zero hits in src/ and zero in migrations), so
-- the drop is safe.
--
-- Validation returns structured jsonb and never raises, per the never-block rule.
-- 'unpriced' is rejected as an input: it is system-assigned by the trigger and a
-- caller asserting it would be claiming an outcome rather than reporting a fact.

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

  -- PRD-022 pricing_status contract
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

-- Born anon-executable otherwise (PRD-113 landmine). Lock it to authenticated.
revoke all on function public.create_po_addition_v2(text, uuid, numeric, numeric, date, text, text, text) from public, anon;
grant execute on function public.create_po_addition_v2(text, uuid, numeric, numeric, date, text, text, text) to authenticated, service_role;

-- Same hole on the RPC the new Price review page calls. Body already rejects a
-- roleless caller, so this is defence in depth, not a live exploit.
revoke all on function public.correct_procurement_unit_price_v1(text, uuid, numeric, text, boolean) from public, anon;
grant execute on function public.correct_procurement_unit_price_v1(text, uuid, numeric, text, boolean) to authenticated, service_role;

-- Cody: the sibling receive path. receive_purchase_order_addition also flips
-- po_additions.status and therefore fires the new unpriced block, so it is
-- inside this migration's blast radius and carries the same anon grant.
revoke all on function public.receive_purchase_order_addition(uuid, uuid, date, text) from public, anon;
grant execute on function public.receive_purchase_order_addition(uuid, uuid, date, text) to authenticated, service_role;

-- S-268, surfaced by the post-apply security advisor. The TRIGGER function was
-- born with the default PUBLIC EXECUTE grant plus anon, so it is reachable at
-- /rest/v1/rpc/procurement_price_sync_and_flag. Calling it directly raises
-- ("trigger functions can only be called as triggers"), so this is noise rather
-- than a live exploit — but its body is replaced above, which puts it in this
-- migration's blast radius. Trigger execution is unaffected: the trigger fires
-- as the table owner, not through these grants. Verified by a full receive
-- after the revoke.
revoke all on function public.procurement_price_sync_and_flag() from public, anon, authenticated;
grant execute on function public.procurement_price_sync_and_flag() to postgres, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4b. Column-level lockdown on po_additions (Cody, Articles 1 + 5)
-- ─────────────────────────────────────────────────────────────────────────────
-- po_additions carries warehouse_update (UPDATE, {authenticated}, no WITH CHECK,
-- no column restriction) on top of the S-308 default grant. Without this, the
-- pricing_status column this migration just created is writable straight from
-- the browser — and because 'free_goods' short-circuits the trigger and nulls
-- price_flag, that would be an unaudited flag-clearing path that bypasses
-- review_price_flag_v1 entirely, open for the whole one-week soak before the
-- po_additions_rpc_only migration lands.
--
-- purchase_orders does not need this: authenticated holds SELECT only there, so
-- RLS already blocks the equivalent write.
--
-- Zero blast radius today — the FE performs no UPDATE on po_additions at all
-- (verified across all five call sites; the only direct write is the INSERT in
-- receiving/[poId]/page.tsx, which step 2 replaces with create_po_addition_v2).
-- Every pre-existing column stays updatable; only the two new governance
-- columns are withheld.

revoke update on public.po_additions from authenticated;
grant update (addition_id, po_id, boonz_product_id, qty, price_per_unit_aed,
              added_by, status, notes, created_at, received_at, received_by,
              expiry_date, wh_location, total_price_aed)
  on public.po_additions to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. review_price_flag_v1 — close a flag with a verdict
-- ─────────────────────────────────────────────────────────────────────────────
-- Clearing price_flag does not re-arm the flagger: the UPDATE moves neither
-- price nor qty, so v_changed is false and the trigger returns the row with the
-- flag as written. For an UNPRICED_RECEIPT row block (c) is entered but the code
-- is unchanged, so it likewise passes through. Verified in both paths below.
--
-- pricing_status is deliberately NOT reset by a review. 'unpriced' is a
-- statement about the money on the row, and reviewing the flag does not put
-- money there — only repricing does.

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

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. _mirror_po_addition_line_v1 — carry pricing_status onto the mirror
-- ─────────────────────────────────────────────────────────────────────────────
-- Without this a free_goods addition mirrors into a purchase_orders line that
-- defaults to 'priced' with a zero total, and the trigger's INSERT path (v_recv
-- true, total 0) immediately stamps it UNPRICED_RECEIPT — a flag on a line whose
-- source row was explicitly asserted correct. Only the new column is added; the
-- price arithmetic is untouched.

create or replace function public._mirror_po_addition_line_v1(p_addition_id uuid, p_actor_id uuid default null::uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_a             public.po_additions%ROWTYPE;
  v_po_number     integer;
  v_supplier_id   uuid;
  v_purchase_date date;
  v_line_id       uuid;
  v_unit          numeric;
  v_total         numeric;
  v_today         date := CURRENT_DATE;
  v_actor         uuid := COALESCE(p_actor_id, (SELECT auth.uid()));
BEGIN
  IF p_addition_id IS NULL THEN RETURN NULL; END IF;

  SELECT * INTO v_a FROM public.po_additions WHERE addition_id = p_addition_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT po_line_id INTO v_line_id
    FROM public.purchase_orders WHERE source_addition_id = p_addition_id;
  IF v_line_id IS NOT NULL THEN RETURN v_line_id; END IF;

  SELECT po_number, supplier_id, purchase_date
    INTO v_po_number, v_supplier_id, v_purchase_date
    FROM public.purchase_orders WHERE po_id = v_a.po_id
    ORDER BY purchase_date LIMIT 1;

  IF v_po_number IS NULL AND v_supplier_id IS NULL THEN RETURN NULL; END IF;

  v_unit  := COALESCE(v_a.price_per_unit_aed,
                      CASE WHEN v_a.total_price_aed IS NOT NULL AND v_a.qty > 0
                           THEN ROUND(v_a.total_price_aed / v_a.qty, 4) END);
  v_total := COALESCE(v_a.total_price_aed,
                      CASE WHEN v_a.price_per_unit_aed IS NOT NULL
                           THEN ROUND(v_a.qty * v_a.price_per_unit_aed, 2) END);

  INSERT INTO public.purchase_orders (
    po_id, po_number, supplier_id, boonz_product_id, purchase_date,
    ordered_qty, received_qty, price_per_unit_aed, total_price_aed,
    expiry_date, received_date, purchase_outcome, source_addition_id,
    pricing_status
  ) VALUES (
    v_a.po_id, v_po_number, v_supplier_id, v_a.boonz_product_id,
    COALESCE(v_purchase_date, v_today),
    v_a.qty, v_a.qty, v_unit, v_total,
    v_a.expiry_date, COALESCE(v_a.received_at::date, v_today), 'received', p_addition_id,
    v_a.pricing_status
  )
  ON CONFLICT (source_addition_id) WHERE source_addition_id IS NOT NULL DO NOTHING
  RETURNING po_line_id INTO v_line_id;

  IF v_line_id IS NULL THEN
    SELECT po_line_id INTO v_line_id
      FROM public.purchase_orders WHERE source_addition_id = p_addition_id;
    RETURN v_line_id;
  END IF;

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (v_a.po_id, 'po_addition_line_mirrored', v_actor,
    jsonb_build_object('addition_id', p_addition_id, 'po_line_id', v_line_id,
      'boonz_product_id', v_a.boonz_product_id, 'qty', v_a.qty,
      'price_per_unit_aed', v_unit, 'total_price_aed', v_total,
      'pricing_status', v_a.pricing_status,
      'note', 'financial mirror only - no warehouse batch created by this write'));

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'INSERT', v_line_id::text, v_actor,
    (SELECT role FROM public.user_profiles WHERE id = v_actor),
    true, '_mirror_po_addition_line_v1',
    jsonb_build_object('po_id', v_a.po_id, 'addition_id', p_addition_id,
                       'qty', v_a.qty, 'total_price_aed', v_total,
                       'pricing_status', v_a.pricing_status));

  RETURN v_line_id;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. receive_purchase_order — total-first line payload
-- ─────────────────────────────────────────────────────────────────────────────
-- Per line, p_lines now accepts:
--   total_price_aed  numeric  — the figure printed on the bill (preferred)
--   pricing_status   text     — 'priced' | 'free_goods'
--   price_per_unit_aed        — still accepted, for back-compat with any caller
--                               that has not been repointed. Every line that
--                               arrives unit-only is counted and surfaced as
--                               legacy_unit_entry in the goods_received payload,
--                               so the soak can see whether the old shape is
--                               still in use before the FE-only assumption is
--                               relied on anywhere.
-- p_additions accepts an optional pricing_status so the warehouse can assert
-- free goods on an addition at receive time.
--
-- When a total arrives, BOTH price_per_unit_aed and total_price_aed are written
-- explicitly. That is deliberate: the trigger's purchase_orders UPDATE branch
-- only derives one from the other when exactly one of them moved, so writing
-- both leaves the RPC's arithmetic authoritative and the trigger inert.
--
-- The received-qty rescale in the unit-only fallback is existing behaviour and
-- is preserved byte-for-byte. This RPC does not add a qty-derivation path to the
-- trigger, so purchase_orders qty edits still never rescale prices.

create or replace function public.receive_purchase_order(p_po_id text, p_lines jsonb, p_additions jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_caller_id          uuid;
  v_role               text;
  v_today              date := CURRENT_DATE;
  v_line               jsonb;
  v_batch              jsonb;
  v_addition           jsonb;
  v_po_line_id         uuid;
  v_addition_id        uuid;
  v_product_id         uuid;
  v_orig_price         numeric;
  v_new_price          numeric;
  v_line_total         numeric;
  v_line_pstat         text;
  v_legacy_unit_lines  integer := 0;
  v_free_goods_lines   integer := 0;
  v_add_pstat          text;
  v_wh_location        text;
  v_total_qty          numeric;
  v_batch_idx          integer;
  v_batch_id           text;
  v_wh_inv_id          uuid;
  v_rows               integer;
  v_received_count     integer := 0;
  v_not_purchased_count integer := 0;
  v_addition_count     integer := 0;
  v_mirrored_count     integer := 0;
  v_mirror_line_id     uuid;
  v_not_purch_names    text[] := '{}';
  v_received_names     text[] := '{}';
  v_prod_name          text;
  v_batch_expiry       date;
  v_addition_expiry    date;
  v_warehouse_id       uuid := public.wh_central_id();
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'receive_purchase_order', true);
  PERFORM set_config('app.provenance_reason', 'po_receive', true);

  v_caller_id := (SELECT auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller_id;
  IF v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'receive_purchase_order: role % not authorized (warehouse+ only)', COALESCE(v_role,'none');
  END IF;
  IF p_po_id IS NULL OR trim(p_po_id) = '' THEN
    RAISE EXCEPTION 'receive_purchase_order: p_po_id is required';
  END IF;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_po_line_id  := (v_line->>'po_line_id')::uuid;
      v_new_price   := CASE WHEN NULLIF(v_line->>'price_per_unit_aed','') IS NOT NULL
                            THEN (v_line->>'price_per_unit_aed')::numeric ELSE NULL END;
      -- PRD-022: the bill total is the preferred input.
      v_line_total  := CASE WHEN NULLIF(v_line->>'total_price_aed','') IS NOT NULL
                            THEN (v_line->>'total_price_aed')::numeric ELSE NULL END;
      v_line_pstat  := COALESCE(NULLIF(v_line->>'pricing_status',''), 'priced');
      IF v_line_pstat NOT IN ('priced','free_goods') THEN v_line_pstat := 'priced'; END IF;
      v_wh_location := NULLIF(v_line->>'wh_location', '');

      SELECT price_per_unit_aed, boonz_product_id INTO v_orig_price, v_product_id
      FROM public.purchase_orders WHERE po_line_id = v_po_line_id AND po_id = p_po_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'receive_purchase_order: po_line_id % not found in PO %', v_po_line_id, p_po_id;
      END IF;
      SELECT boonz_product_name INTO v_prod_name FROM public.boonz_products WHERE product_id = v_product_id;

      IF (v_line->>'close_as_not_purchased')::boolean IS TRUE THEN
        UPDATE public.purchase_orders SET received_date = v_today, received_qty = 0, purchase_outcome = 'not_purchased'
        WHERE po_line_id = v_po_line_id;
        v_not_purchased_count := v_not_purchased_count + 1;
        v_not_purch_names := array_append(v_not_purch_names, COALESCE(v_prod_name,'?'));
        CONTINUE;
      END IF;

      v_batch_idx := 0; v_total_qty := 0;
      SELECT COALESCE(SUM((b->>'received_qty')::numeric), 0) INTO v_total_qty
      FROM jsonb_array_elements(COALESCE(v_line->'batches','[]'::jsonb)) AS b
      WHERE (b->>'received_qty')::numeric > 0;
      IF v_total_qty <= 0 THEN CONTINUE; END IF;

      FOR v_batch IN SELECT * FROM jsonb_array_elements(COALESCE(v_line->'batches','[]'::jsonb)) LOOP
        IF COALESCE((v_batch->>'received_qty')::numeric, 0) > 0
           AND NULLIF(v_batch->>'expiry_date','') IS NULL THEN
          RAISE EXCEPTION
            'receive_purchase_order: PO % line % (% — %): batch has received_qty=% but missing expiry_date. Capture supplier expiry before receiving (NULL-expiry rows are forbidden, BUG-007/009).',
            p_po_id, v_po_line_id, v_prod_name, v_batch->>'wh_location',
            v_batch->>'received_qty';
        END IF;
      END LOOP;

      -- PRD-022 telemetry: a line that arrived unit-only came from a caller that
      -- has not been moved to total-first yet. Advisory only, never blocking.
      IF v_line_total IS NULL AND v_new_price IS NOT NULL THEN
        v_legacy_unit_lines := v_legacy_unit_lines + 1;
      END IF;
      IF v_line_pstat = 'free_goods' THEN
        v_free_goods_lines := v_free_goods_lines + 1;
      END IF;

      UPDATE public.purchase_orders
      SET received_date = v_today, received_qty = v_total_qty, purchase_outcome = 'received',
          pricing_status = v_line_pstat,
          price_per_unit_aed = CASE
            WHEN v_line_total IS NOT NULL AND v_total_qty > 0
              THEN ROUND(v_line_total / v_total_qty, 4)
            ELSE COALESCE(v_new_price, price_per_unit_aed) END,
          total_price_aed = CASE
            WHEN v_line_total IS NOT NULL THEN v_line_total
            WHEN v_new_price IS NOT NULL THEN v_total_qty * v_new_price
            WHEN price_per_unit_aed IS NOT NULL THEN v_total_qty * price_per_unit_aed
            ELSE NULL END,
          expiry_date = COALESCE(NULLIF((v_line->'batches'->0->>'expiry_date'),'')::date, expiry_date)
      WHERE po_line_id = v_po_line_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'receive_purchase_order: failed to update po_line_id %', v_po_line_id;
      END IF;

      PERFORM set_config('app.source_event_id', v_po_line_id::text, true);

      FOR v_batch IN SELECT * FROM jsonb_array_elements(COALESCE(v_line->'batches','[]'::jsonb)) LOOP
        CONTINUE WHEN COALESCE((v_batch->>'received_qty')::numeric,0) <= 0;
        v_batch_idx := v_batch_idx + 1;
        v_batch_id  := p_po_id || '-' || left(v_po_line_id::text,8) || '-B' || v_batch_idx;
        v_batch_expiry := NULLIF(v_batch->>'expiry_date','')::date;

        INSERT INTO public.warehouse_inventory (
          boonz_product_id, warehouse_stock, expiration_date,
          batch_id, wh_location, status, snapshot_date, warehouse_id
        ) VALUES (
          v_product_id, (v_batch->>'received_qty')::numeric, v_batch_expiry,
          v_batch_id, v_wh_location, 'Active', v_today, v_warehouse_id
        ) RETURNING wh_inventory_id INTO v_wh_inv_id;

        IF v_new_price IS NOT NULL AND v_new_price IS DISTINCT FROM v_orig_price THEN
          BEGIN
            INSERT INTO public.inventory_audit_log (
              wh_inventory_id, boonz_product_id, adjusted_by,
              old_qty, new_qty, delta, reason
            ) VALUES (
              v_wh_inv_id, v_product_id, v_caller_id,
              COALESCE(v_orig_price,0), v_new_price, v_new_price - COALESCE(v_orig_price,0),
              'price_adjusted_at_receipt');
          EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'audit log failed for wh_inv %: %', v_wh_inv_id, SQLERRM;
          END;
        END IF;
      END LOOP;
      v_received_count := v_received_count + 1;
      v_received_names := array_append(v_received_names, COALESCE(v_prod_name,'?'));
    END LOOP;
  END IF;

  IF p_additions IS NOT NULL AND jsonb_typeof(p_additions) = 'array' AND jsonb_array_length(p_additions) > 0 THEN
    FOR v_addition IN SELECT * FROM jsonb_array_elements(p_additions) LOOP
      v_product_id := (v_addition->>'boonz_product_id')::uuid;
      v_addition_id := (v_addition->>'addition_id')::uuid;
      v_batch_id   := p_po_id || '-ADD-' || left((v_addition->>'addition_id'),8);

      v_addition_expiry := COALESCE(
        NULLIF(v_addition->>'expiry_date','')::date,
        (SELECT expiry_date FROM po_additions WHERE addition_id = v_addition_id)
      );
      IF v_addition_expiry IS NULL THEN
        RAISE EXCEPTION
          'receive_purchase_order: addition % (% qty=%) has no expiry_date in jsonb or po_additions. Capture expiry before receiving.',
          v_addition->>'addition_id', v_product_id, v_addition->>'qty';
      END IF;

      -- PRD-022: the warehouse may assert free goods on an addition at receipt.
      v_add_pstat := NULLIF(v_addition->>'pricing_status','');
      IF v_add_pstat IS NOT NULL AND v_add_pstat NOT IN ('priced','free_goods') THEN
        v_add_pstat := NULL;
      END IF;
      IF v_add_pstat = 'free_goods' THEN
        v_free_goods_lines := v_free_goods_lines + 1;
      END IF;

      UPDATE public.po_additions
      SET status = 'received', received_at = now(), received_by = v_caller_id,
          pricing_status = COALESCE(v_add_pstat, pricing_status)
      WHERE addition_id = v_addition_id
        AND po_id = p_po_id AND status = 'pending_receive';

      -- PRD-003: mirror the addition into a real purchase_orders line, atomically, so the PO card
      -- total and every cost read stop silently excluding it. Financial line ONLY — this creates
      -- no warehouse batch; the WH credit is the INSERT below, unchanged.
      v_mirror_line_id := public._mirror_po_addition_line_v1(v_addition_id, v_caller_id);
      IF v_mirror_line_id IS NOT NULL THEN
        v_mirrored_count := v_mirrored_count + 1;
      END IF;

      PERFORM set_config('app.source_event_id', v_addition_id::text, true);

      INSERT INTO public.warehouse_inventory (
        boonz_product_id, warehouse_stock, expiration_date,
        batch_id, wh_location, status, snapshot_date, warehouse_id
      ) VALUES (
        v_product_id, (v_addition->>'qty')::numeric, v_addition_expiry,
        v_batch_id, NULLIF(v_addition->>'wh_location',''), 'Active', v_today, v_warehouse_id
      );
      v_addition_count := v_addition_count + 1;
    END LOOP;
  END IF;

  IF v_received_count > 0 OR v_addition_count > 0 THEN
    INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
    VALUES (p_po_id, 'goods_received', v_caller_id,
      jsonb_build_object('lines_received', v_received_count, 'additions_received', v_addition_count,
                         'additions_mirrored', v_mirrored_count, 'products', to_json(v_received_names),
                         'legacy_unit_entry', v_legacy_unit_lines > 0,
                         'legacy_unit_lines', v_legacy_unit_lines,
                         'free_goods_lines', v_free_goods_lines));
  END IF;
  IF v_not_purchased_count > 0 THEN
    INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
    VALUES (p_po_id, 'line_not_purchased', v_caller_id,
      jsonb_build_object('count', v_not_purchased_count, 'products', to_json(v_not_purch_names)));
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'po_id', p_po_id, 'received_date', v_today,
    'lines_received', v_received_count, 'lines_not_purchased', v_not_purchased_count,
    'additions_received', v_addition_count, 'additions_mirrored', v_mirrored_count,
    'legacy_unit_lines', v_legacy_unit_lines, 'free_goods_lines', v_free_goods_lines);
EXCEPTION WHEN OTHERS THEN RAISE;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. v_po_price_flags — surface pricing_status to the review page
-- ─────────────────────────────────────────────────────────────────────────────
-- pricing_status is APPENDED as the last column, not slotted in beside
-- flag_code where it reads better. CREATE OR REPLACE VIEW can only add columns
-- at the end — inserting one mid-list raises 42P16 ("cannot change name of view
-- column") — and dropping the view to reorder would be a needless dependency
-- risk for cosmetics.

create or replace view public.v_po_price_flags as
 select 'po_additions'::text as source_table,
    a.addition_id::text as row_id,
    a.po_id,
    bp.boonz_product_name,
    a.created_at::date as row_date,
    a.qty,
    a.price_per_unit_aed as unit_aed,
    a.total_price_aed as total_aed,
    a.status,
    a.price_flag ->> 'code'::text as flag_code,
    a.price_flag,
    a.pricing_status
   from po_additions a
     join boonz_products bp on bp.product_id = a.boonz_product_id
  where a.price_flag is not null
union all
 select 'purchase_orders'::text as source_table,
    po.po_line_id::text as row_id,
    po.po_id,
    bp.boonz_product_name,
    po.purchase_date as row_date,
    coalesce(nullif(po.received_qty, 0::numeric), po.ordered_qty) as qty,
    po.price_per_unit_aed as unit_aed,
    po.total_price_aed as total_aed,
    po.purchase_outcome as status,
    po.price_flag ->> 'code'::text as flag_code,
    po.price_flag,
    po.pricing_status
   from purchase_orders po
     join boonz_products bp on bp.product_id = po.boonz_product_id
  where po.price_flag is not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Backfill — idempotent
-- ─────────────────────────────────────────────────────────────────────────────
-- Every UPDATE below is re-runnable: each one filters on the state it is about
-- to write, so a second run touches zero rows.
--
-- The flag is written explicitly rather than left to the trigger. On these rows
-- the receive transition happened months ago, so v_recv is false and block (c)
-- is not entered; and because neither price nor qty moves, v_changed is false
-- and the trigger returns the row with the flag exactly as written. The
-- backfilled marker matches the convention set by po_price_total_first_flag_only.
--
-- Scope at time of writing: 3 po_additions rows, 18 purchase_orders rows.
-- purchase_outcome = 'not_purchased' (301 rows) and NULL / open lines (21 rows)
-- are deliberately out of scope: no goods landed, so there is nothing unpriced.

update public.po_additions
   set pricing_status = 'unpriced',
       price_flag = jsonb_build_object(
         'code',                 'UNPRICED_RECEIPT',
         'unit_aed',             price_per_unit_aed,
         'total_aed',            total_price_aed,
         'qty',                  qty,
         'peer_median_unit_aed', null,
         'peer_observations',    null,
         'unit_vs_median_pct',   null,
         'suggested_unit_aed',   null,
         'backfilled',           true,
         'flagged_at',           now())
 where status = 'received'
   and coalesce(total_price_aed, 0) = 0
   and pricing_status = 'priced';

update public.purchase_orders
   set pricing_status = 'unpriced',
       price_flag = jsonb_build_object(
         'code',                 'UNPRICED_RECEIPT',
         'unit_aed',             price_per_unit_aed,
         'total_aed',            total_price_aed,
         'qty',                  coalesce(nullif(received_qty, 0), ordered_qty),
         'peer_median_unit_aed', null,
         'peer_observations',    null,
         'unit_vs_median_pct',   null,
         'suggested_unit_aed',   null,
         'backfilled',           true,
         'flagged_at',           now())
 where purchase_outcome = 'received'
   and coalesce(total_price_aed, 0) = 0
   and pricing_status = 'priced';

-- The Vitamin Well - Care addition on PO-2026-9400 (219fc9b2) is deliberately
-- NOT touched. Union Coop billed 1 pc at 9.25 and gave 7 free, and the line was
-- corrected on 2026-08-11 to carry the blended 9.25 across all 8 units.
--
-- PRD-022 asked for it to be marked free_goods. Cody blocked that and I agree:
-- free_goods is defined three sections above as a human assertion that 0.00 is
-- correct, and this row's total is 9.25. create_po_addition_v2 in this same
-- migration would refuse to create it (FREE_GOODS_WITH_PRICE), so writing it
-- here would seed a state the canonical writer can neither reproduce nor
-- repair. The standing decision — mixed lines carry blended totals — is what
-- this row already does, and 'priced' is the honest label for money that was
-- actually paid.
--
-- The row is unflagged today. If the peer median ever moves far enough to trip
-- PRICE_LOW on its 1.1563 unit, review_price_flag_v1(verdict =
-- 'confirmed_correct') is the instrument for silencing it, and it leaves a
-- note and an audit row behind. That is strictly better than a label that is
-- false on its face.

-- One summary audit row rather than 21 individual ones: this is a single
-- schema-level act, not 21 human decisions.
insert into public.write_audit_log (
  table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
)
select 'po_additions,purchase_orders', 'UPDATE', 'po_pricing_status_v1_backfill',
       null, 'migration', false, 'po_pricing_status_v1',
       jsonb_build_object(
         'event', 'unpriced_receipt_backfill',
         'po_additions_rows', (select count(*) from public.po_additions
                                where pricing_status = 'unpriced'),
         'purchase_orders_rows', (select count(*) from public.purchase_orders
                                   where pricing_status = 'unpriced'),
         'note', 'received rows carrying no money, flagged UNPRICED_RECEIPT (advisory)');

commit;
