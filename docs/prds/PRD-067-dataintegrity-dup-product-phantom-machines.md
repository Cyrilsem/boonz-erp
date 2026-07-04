# PRD-067: Data integrity - duplicate product name + phantom machines

Status: Open (kept open, PRD-071 sweep 2026-07-02). Verdict: phantom-machine cleanup executed in the overnight run (318afd4); CS DECIDED 2026-07-04: ONE product, survivor = 4edc4fbb "Hunter Ridge - Sour Cream" (NO rename); merge 285479a7 "Sour Cream & Onion" refs into it via the PRD-062 pattern, then delete 285479a7 after zero-ref scan. Remaining build: the merge migration + the 76 orphan JET-2001-3000-O1 product_mapping rows.

Owner: CS. Date: 2026-06-30. Surface: data cleanup on prod. Touches boonz_products, product_mapping, pod_inventory, machines (Articles 1,3,12). Cody review mandatory; migration FILE first; STOP for CS before any DELETE / status flip. Idempotent, no em dashes.

## Problems (from the 30/06 "Pod Inventory Need to Adjust" list, verified live 2026-06-30)

### 1. Duplicate product name - "Sour Cream"

Two boonz_products exist:

- `4edc4fbb-cf97-49eb-8c1d-cb5f24963f8e` "Hunter Ridge - Sour Cream" - the LIVE product: 23 product_mapping rows, 41 pod rows (27 active units), 11 WH rows, 162 dispatch rows.
- `285479a7-ea9f-4bb1-bc15-62c7581d7211` "Hunter Ridge - Sour Cream & Onion" - near-dead but NOT empty: 0 mappings, 6 pod rows (0 active units), 1 WH row, 17 dispatch rows.

CORRECTION (verified live 2026-06-30): the original doc premise ("285479a7 is an empty shell, delete it") was WRONG - it was based on a mappings+active-pod-only count. 285479a7 has 24 residual references, so it CANNOT be blind-deleted. The overnight run correctly skip-logged this.

PREREQUISITE DECISION (CS): are these ONE physical product mislabeled, or two genuine Hunter Ridge flavors (plain Sour Cream AND Sour Cream & Onion)? 285479a7 has zero active deployment, which points to a stray duplicate, but confirm before merging.

- If SAME product (CS says the physical item is "Sour Cream & Onion"): this is a PRD-062-style MERGE, not a delete. Repoint 285479a7's 17 dispatch + 6 pod + 1 WH refs into the survivor `4edc4fbb` (conflict-handle unique keys, conserve stock), RENAME `4edc4fbb` -> "Hunter Ridge - Sour Cream & Onion", then DELETE `285479a7` after a zero-ref scan.
- If TWO genuine flavors: leave both, no action; just note the near-dead footprint of 285479a7.

### 2. Phantom JET machine in Product Mapping

- `JET-1016-0000-O1` - REAL (Active, 34 pod rows, 118 units).
- `JET-2001-3000-O1` - PHANTOM (already status=Inactive, 0 pod rows, 0 units) but still carries 76 product_mapping rows, so it shows as a 2nd "Jet" in Product Mapping.
  Fix: delete the 76 orphan product_mapping rows for `JET-2001-3000-O1` so it stops appearing. Machine already Inactive; leave the machine row for audit history.

### 3. Phantom warehouse machine WH2-2001-3000-O1

- status='Warehouse', 57 active pod rows, 102 units (expired stock), 226 product_mapping rows. Not a real machine ("we don't have any machine by this name"). Shares the 2001-3000-O1 suffix with the phantom JET - a bad legacy import.
  Fix: (a) write off the 57 active pod rows via `backfill_archive_pod_inventory_row` (server-side, no WH credit - this is expired phantom stock, not real); (b) delete the 226 orphan product_mapping rows; (c) flip machine status Warehouse -> Inactive. STOP for CS before the status flip and the pod write-off.

## Rules

- Migration FILE first; apply on CS sign-off; STOP before each DELETE / status flip / pod write-off.
- Idempotent: re-running finds the row already renamed / deleted / inactive and no-ops.
- CONSERVATION: the Sour Cream rename moves zero stock. The phantom write-offs remove ONLY phantom/expired pod stock and must NOT credit warehouse_inventory (assert WH unchanged). Print before/after counts.
- Per-table reference scan (information_schema) for `285479a7` before its DELETE to confirm zero refs.
- Cody verdict required for all three.

## Acceptance

- One "Sour Cream" product remains, correctly named; the empty shell is gone.
- `JET-2001-3000-O1` has zero product_mapping rows and no longer shows as a 2nd Jet.
- `WH2-2001-3000-O1` is Inactive with zero active pod rows and zero mappings; WH stock unchanged; write-offs logged.
- Every step idempotent and logged; any unresolved ref SKIPPED + logged, not forced.
