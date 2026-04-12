# Canonical Refill Formula

## Formula

```python
daily_avg = sales_last_30d / 30
target_qty = min(
    max(ceil(daily_avg * days_cover), floor_qty),
    slot_max_capacity          # from v_live_shelf_stock.max_stock
)
refill_qty = max(target_qty - current_stock, 0)
```

## Field sources

| Field             | Source                                                                |
| ----------------- | --------------------------------------------------------------------- |
| sales_last_30d    | v_sales_history_attributed, 30d window, machine_id + pod_product_name |
| days_cover        | machine_modes.md — varies by mode                                     |
| floor_qty         | machine_modes.md — varies by mode                                     |
| slot_max_capacity | v_live_shelf_stock.max_stock                                          |
| current_stock     | v_live_shelf_stock.current_stock                                      |

## Output fields (always log both)

- target_qty — velocity-derived goal
- slot_max_capacity — physical ceiling (from Weimi API)
- refill_qty — units to load

## Skip conditions

- refill_qty == 0 → skip slot entirely, do not include in plan
- is_enabled == false → skip slot
- is_broken == true → skip slot

## New product SWAP minimums (no velocity history)

| Category                         | Minimum |
| -------------------------------- | ------- |
| Drinks (attr_drink = true)       | 6 units |
| Snacks/food (attr_drink = false) | 4 units |

Cap at slot_max_capacity if slot is smaller than minimum.

## Delivery status filter

Always filter: delivery_status IN ('Success', 'Successful')
Never include failed/refunded transactions in velocity.
