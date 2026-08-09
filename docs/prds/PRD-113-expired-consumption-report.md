# PRD-113 — 30-day expired-consumption repair report

Generated **2026-08-10** (Dubai). Window: `now() - 30 days` → now.

This is a **report, not a repair.** Nothing below has been restored, and nothing will be
restored automatically. PRD-113 fix 2.3: CS decides each line by hand.

## What it measures

Every `pod_inventory_audit_log` row written by the FIFO sales decrement
(`source = 'sale'`, `delta < 0`) whose batch was **already past its expiration date on the
day the decrement ran** — i.e. units the pipeline recorded as sold that were physically
expired stock sitting in the machine.

```sql
SELECT m.official_name AS machine,
       COALESCE(sc.shelf_code, pi.shelf_id::text, '-') AS shelf,
       bp.boonz_product_name AS product,
       pi.expiration_date AS batch_expiry,
       SUM(-al.delta)::numeric AS units_consumed_expired,
       COUNT(*) AS decrement_events,
       MIN((al.created_at AT TIME ZONE 'Asia/Dubai')::date) AS first_event,
       MAX((al.created_at AT TIME ZONE 'Asia/Dubai')::date) AS last_event,
       pi.pod_inventory_id, pi.status, pi.current_stock
FROM pod_inventory_audit_log al
JOIN pod_inventory pi   ON pi.pod_inventory_id = al.pod_inventory_id
JOIN machines m         ON m.machine_id        = al.machine_id
LEFT JOIN boonz_products bp        ON bp.product_id = al.boonz_product_id
LEFT JOIN shelf_configurations sc  ON sc.shelf_id   = pi.shelf_id
WHERE al.source = 'sale'
  AND al.delta  < 0
  AND al.created_at >= now() - interval '30 days'
  AND pi.expiration_date IS NOT NULL
  AND pi.expiration_date < (al.created_at AT TIME ZONE 'Asia/Dubai')::date
GROUP BY m.official_name, sc.shelf_code, pi.shelf_id, bp.boonz_product_name,
         pi.expiration_date, pi.pod_inventory_id, pi.status, pi.current_stock
ORDER BY SUM(-al.delta) DESC;
```

## Findings — 3 batches, 14 units

| machine            | shelf | product                            | batch expiry | units consumed while expired | events | first      | last       | batch now         |
| ------------------ | ----- | ---------------------------------- | ------------ | ---------------------------: | -----: | ---------- | ---------- | ----------------- |
| VML-1004-0500-O1   | A14   | Kinder Delice - Cake               | 2026-07-17   |                       **11** |     11 | 2026-07-20 | 2026-07-23 | Inactive, stock 0 |
| AMZ-1038-3001-O1   | A09   | G&H Popped Chips - Sweet And Salty | 2026-07-20   |                        **2** |      2 | 2026-07-21 | 2026-07-23 | Inactive, stock 0 |
| ALJLT-1015-0100-B1 | A07   | Bounty - Regular                   | 2026-08-01   |                        **1** |      1 | 2026-08-04 | 2026-08-04 | Inactive, stock 0 |

**Total: 14 units across 3 batches, 3 machines.**

Each batch was drained to zero and flipped `Inactive` with
`removal_reason = 'sold_through_<date>'`. In every case the units are recorded as revenue
that a physically-expired batch cannot have produced: either the sale was really served by a
different (non-expired) batch whose count is now overstated, or the expired units are still
in the machine and the count is understated by that amount.

## Caveats CS should weigh before restoring anything

1. **`expiration_date` is read as it stands today.** If a batch's expiry was corrected after
   the decrement ran, this classification reflects the corrected value, not the value in
   force at the time.
2. **Volume is small and recent.** 14 units over 30 days across a 57-pod fleet. The rule is
   worth fixing on principle (it is the standing CS iron rule and v3 LAW 7), not because of
   a large outstanding balance.
3. **All three batches are already `Inactive` at stock 0.** Restoration means re-activating a
   batch and setting a non-zero `current_stock` on `pod_inventory` — a protected-entity
   write. It needs the propose-then-confirm path, per row, with CS approval. Not done here.

## Recommended action

Physically check the three shelves. If expired units are still present, write them off
through the existing manual write-off flow so the exit is recorded as a write-off rather
than as a sale. If the shelves are empty, no restoration is needed — only the revenue
attribution was wrong, and that is not reversible from here.

Going forward `auto_decrement_pod_inventory` cannot produce new rows of this kind: expired
batches are ineligible, and any sale it cannot absorb from non-expired stock is reported to
`monitoring_alerts` under `prd113_fifo_expired_overflow`.
