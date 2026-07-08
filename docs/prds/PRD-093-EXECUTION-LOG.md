# PRD-093 Execution Log — Consignment SKU model (Part A SHIP DARK; Part B PARKED)

Run 2026-07-08 overnight (WAVE1-OVERNIGHT), AUTO. **Status: Part A SHIPPED DARK; Part B PARKED.**
Other-3 Family A `11b0b03f` UNCHANGED; engine_add_pod UNTOUCHED by Part A.

## Shipped (Part A — additive, inert)
- `boonz_products.is_consignment boolean NOT NULL DEFAULT false` + `consignment_venue_id uuid`.
- `consignment_v1` flag seeded OFF. Columns are inert (nothing reads them yet) — `diff_vs_golden`
  IDENTICAL. Lets CS begin tagging venue-sourced SKUs (VOX Aquafina / Ice Tea / M&M).
- Cody fast-path: additive columns on non-protected `boonz_products` (Article 12/14 clean).

## Parked (Part B — engine gating behind consignment_v1)
Making `engine_add_pod` skip `wh_avail` gating for consignment SKUs (never emit
`blocked_no_wh`/`procurement_gaps`, size to cap) is NOT shipped. Two blockers:
1. **Unvalidatable ON behaviour** — the golden fixture is 100% manual/non-engine-sized rows;
   no plan_date in 30d exercises the engine's `blocked_no_wh`/`wh_avail` path, so the ON delta
   cannot be validated (rule F). 
2. **pod_product→boonz mapping** — the engine works in `pod_product_id`; `is_consignment` is on
   `boonz_products`. Propagating the flag into the engine's per-row data needs the mapping (same
   class as the PRD-090 footprint-source issue) + a Dara design pass on the join.

## Needed to un-park Part B
Engine-ADD fixture (to validate) + pod_product↔boonz consignment mapping + the flag-gated
wh_avail-skip edit, then flag-off identical + ON conservation-excludes-consignment (T3), Cody PASS.

## Status: Part A SHIPPED DARK (columns). Part B PARKED (unvalidatable engine gating). Owner: Dara + CS.
