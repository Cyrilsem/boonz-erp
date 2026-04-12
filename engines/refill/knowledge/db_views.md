# Database Views — Engine Reference

Project: eizcexopcuoycuosittm (ap-south-1)

## v_live_shelf_stock

Primary slot state oracle. Reads live from weimi_device_status.
Key columns:
machine_id uuid, machine_name text, aisle_code text, slot_name text,
goods_name_raw text, pod_product_id uuid, match_method text,
current_stock int, max_stock int, fill_pct int,
is_broken bool, is_enabled bool, price_aed numeric,
snapshot_at timestamptz, is_eligible_machine bool

Filter for active slots: is_enabled = true AND is_broken = false
Filter for eligible machines: is_eligible_machine = true
Always: .limit(10000)

## v_sales_history_attributed

Transaction-level sales. Use for velocity calculation.
Key columns:
machine_id uuid, attributed_name text, pod_product_name text,
qty numeric, transaction_date timestamptz, delivery_status text,
attributed_location_type text

Always filter: delivery_status IN ('Success','Successful')
Velocity window: transaction_date >= NOW() - INTERVAL '30 days'
Always: .limit(10000)

## v_pod_inventory_latest

Latest inventory snapshot per machine+product.
Key columns: machine_id, pod_product_id, estimated_remaining,
expiration_date, days_to_expiry

## machines

Key columns for engine use:
machine_id, official_name, location_type, include_in_refill,
cabinet_count, building_id, source_of_supply, venue_group,
repurposed_at, status

Filter for refill scope: include_in_refill = true AND repurposed_at IS NULL

## boonz_products

Key columns added for engine use:
product_id, boonz_product_name, product_category, category_group,
attr_drink, physical_type (NEW — 15-value enum)
