# PRD-080 Execution Log — FEFO reservation (DARK)

Run 2026-07-07 overnight, AUTO. **Status: SHIPPED DARK (fefo_reserve_v1=off).** Cody PASS
(⚠️→revisions applied). Family A md5 `8587be9a` UNCHANGED.

## Shipped (behind fefo_reserve_v1, seeded off)

- `wh_reservation` table (RLS SELECT-only; writes via DEFINER fns; partial indexes on active).
- `bind_fefo_reserved(dispatch_id, ttl=240)` — DARK no-op when flag off; when on, FEFO-selects a
  v_wh_pickable batch and inserts an active reservation (soft hold; does NOT touch warehouse_inventory).
- `release_fefo_reservation(dispatch_id, reason)` — sets released/consumed. Both set app.via_rpc.

## T-tests (rolled-back trial)

| Test                                          | Result                                                                         |
| --------------------------------------------- | ------------------------------------------------------------------------------ |
| flag OFF ⇒ bind no-op (NULL, 0 reservations)  | PASS (the dark-ship guarantee)                                                 |
| flag ON ⇒ bind executes FEFO query gracefully | PASS (returned NULL on a synthetic product with no pickable batch; code valid) |
| Family A md5 byte-identical                   | PASS (8587be9a)                                                                |
| touches warehouse_inventory                   | NO (soft hold only — Cody Article 6 check)                                     |
| cody                                          | PASS (via_rpc added; dual-mechanism flagged for enable)                        |

Note: a positive ON-path reservation-creation test was not obtained synthetically (v_wh_pickable
membership needs a fuller fixture than a throwaway product). Dark ship does not depend on it;
ON-path validation is part of the parked enable against real batches.

## Parked (enable — Ops + Dara, Article 14)

1. **Enable fefo_reserve_v1** — needs Ops TTL value + reservation-shape ruling (qty-scoped vs
   whole-batch) + **dual-mechanism resolution** vs warehouse_inventory.reserved_for_machine_id
   (don't run two pinning systems in parallel — Cody Article 14) + release-hook wiring into
   pack/return. {owner: Ops/Dara/CS}

## Status: SHIPPED DARK. Enable parked (Ops TTL + shape + Article-14 dual-mechanism).
