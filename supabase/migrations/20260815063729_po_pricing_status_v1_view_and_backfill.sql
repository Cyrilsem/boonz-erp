-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Part 2/4 of the 2026-08-15 pricing_status rollout (see 20260815092204_po_pricing_status_v1.sql).
-- v_po_price_flags gains pricing_status APPENDED LAST (mid-list insertion raises 42P16).

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

-- Body NOT recoverable: the idempotent backfill portion of this migration (3 po_additions +
-- 18 purchase_orders received-with-no-money rows -> pricing_status='unpriced' +
-- UNPRICED_RECEIPT price_flag with backfilled:true) was a one-off data mutation.
-- intentionally empty: data fix already applied to prod 20260815063729 -- the rows now carry
-- pricing_status/price_flag values indistinguishable from a normal trigger-driven stamp, so
-- there is no separate current-state trace to replay this as an idempotent statement.
