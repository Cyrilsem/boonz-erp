-- C: name-resolver foundation. 17 WEIMI slot names had no pod_products match, causing
-- (a) phantom pod rows invisible in machine views, (b) engine planogram-fallback misfires.
-- Additive only: alias table + seed + monitoring view. Engine wiring = separate Cody-reviewed PRD.

create table if not exists public.weimi_product_alias (
  weimi_name     text not null,
  pod_product_id uuid not null references public.pod_products(pod_product_id),
  created_at     timestamptz not null default now(),
  note           text,
  primary key (weimi_name, pod_product_id)
);
comment on table public.weimi_product_alias is
  'Maps WEIMI slot product_name variants to pod_products when names drifted. Read-only reference for resolvers/monitoring.';

insert into public.weimi_product_alias (weimi_name, pod_product_id, note)
select v.weimi_name, pp.pod_product_id, 'seed 2026-07-02 fleet cleanup'
from (values
 ('Plaay Truffle 2pcs','Plaay Protein Balls 2P'),('Plaay Truffle 2pcs','Plaay Truffles - Mix'),
 ('Plaay Tablet Chocolate','Plaay Tablets'),('Plaay Tablet Chocolate','Plaay Tablets - Mix'),
 ('Plaay Cylinder','Plaay Tablets'),('Plaay Cylinder','Plaay Tablets - Mix'),
 ('Freakin Healthy Granola Bar','Freakin Healthy Garnola Bar'),
 ('Freakin Healthy Thins','Freakin Awesome Thins'),
 ('Freakin Awesome Dates','Freakin Awesome Filled Dates'),
 ('Freakin Healthy Balls 3P','Freakin Protein Balls 3P'),
 ('Rice & Corn Family Harvest','Rice & Corn Chips'),
 ('Evian 1L','Evian - 1L'),
 ('Awa Mix','awa sparkling water Flavored'),
 ('Eviron Wellness','Eviron Health Drink'),
 ('M&M bag','M&M Chocolate Bag'),('M&M bag','M&M Bags'),
 ('Chewing Gum','Extra Gum'),
 ('Keen Health - Chocolate Mix','Keen Health Dipped Crackers'),
 ('Coco Max - Regular','Coco Max'),
 ('Tan Tan Dry Fruits','Tan Tan Dry')
) v(weimi_name, pod_name)
join public.pod_products pp on pp.pod_product_name = v.pod_name
on conflict do nothing;

create or replace view public.v_pod_phantom_stock as
with latest as (
  select machine_id, max(snapshot_date) d from weimi_aisle_snapshots group by machine_id
  having max(snapshot_date) >= current_date - 3
), weimi_pods as (
  select distinct s.machine_id, pp.pod_product_id
  from weimi_aisle_snapshots s
  join latest l on l.machine_id = s.machine_id and l.d = s.snapshot_date
  join pod_products pp
    on pp.pod_product_name = s.product_name
    or exists (select 1 from weimi_product_alias a
               where a.weimi_name = s.product_name and a.pod_product_id = pp.pod_product_id)
)
select m.official_name, pi.pod_inventory_id, bp.boonz_product_name,
       pi.current_stock, pi.expiration_date, pi.batch_id,
       (not exists (select 1 from product_mapping pm where pm.boonz_product_id = pi.boonz_product_id)) as missing_mapping
from pod_inventory pi
join machines m on m.machine_id = pi.machine_id
join latest l on l.machine_id = pi.machine_id
join boonz_products bp on bp.product_id = pi.boonz_product_id
where pi.status = 'Active' and pi.current_stock > 0
  and not exists (
    select 1 from weimi_pods w
    join product_mapping pm on pm.pod_product_id = w.pod_product_id
                           and pm.boonz_product_id = pi.boonz_product_id
    where w.machine_id = pi.machine_id);
comment on view public.v_pod_phantom_stock is
  'Active pod rows invisible on the machine per latest WEIMI (alias-aware). Should be ~empty; rows here = phantom stock or a missing alias/mapping.';
