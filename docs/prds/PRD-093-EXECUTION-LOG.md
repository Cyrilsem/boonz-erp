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

## ON-delta (rollback ON-capture, 2026-07-08)

Rollback ON-capture with the flag forced ON in-transaction (BEGIN..ROLLBACK, discarded):
**plan-delta = 0** on golden_v1 (2026-07-06), conservation green (orphan_removal/phantom/oversub = 0).
This is the fixture limitation, not an inertness claim: golden_v1 is 100% manual_add with no
engine-ADD-sized rows, so no Wave-1 change can bite here. A non-zero delta requires an
engine-ADD fixture (see MASTER-PARKING-LOT program blocker).

## REAL delta vs golden_v2 (rich 17-machine fixture, 2026-07-09)

Baseline-vs-candidate rollback on engine-dense 2026-07-01 (235 rows, 17 machines): **delta = 0**,
conservation green. NOT a fixture artifact this time — the trigger conditions don't occur on real
data (velocity>0 shelves already sized above the floors; under-faced shelves are dead/excluded).
089/090 correctly implemented but currently inert. See GOLDEN-V2-EXECUTION-LOG.md.

## 2026-07-09 — Consignment seed PREPARED (NOT enabled)

Per WS-093seed: candidate `is_consignment=true` list for **CS confirmation** (NOT applied; column exists from Part A).
VOX machines carrying these: VOXMCC-1005-0201-B0, VOXMCC-1011-0101-B0, VOXMM-1013-0101-B0.
Candidate boonz_products (venue-supplied):

- Aquafina - Regular (`4fb8965d`)
- Ice Tea - Peach (`de915c25`)
- M&M - Chocolate Nuts (`1a8a2006`) / M&M Bag - Brown (`d19fbbbd`) / M&M Bag - Yellow (`e112924f`) / M&M Chocolate Bag - Regular (`13177887`)
  **CS to confirm**: which of these to tag, and whether product-level (`is_consignment`) or venue-scoped
  (`consignment_venue_id` = the VOX venue) — since M&M may be stocked elsewhere. Then Part B engine gating
  (behind `consignment_v1`) is built in the freeze window. NO tagging applied here.
