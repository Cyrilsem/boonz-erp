# PRD-067: Data integrity - duplicate product name + phantom machines

Owner: CS. Date: 2026-06-30. Surface: data cleanup on prod. Touches boonz_products, product_mapping, pod_inventory, machines (Articles 1,3,12). Cody review mandatory; migration FILE first; STOP for CS before any DELETE / status flip. Idempotent, no em dashes.

## Problems (from the 30/06 "Pod Inventory Need to Adjust" list, verified live 2026-06-30)

### 1. Duplicate product name - "Sour Cream"

Two boonz_products exist:

- `4edc4fbb-cf97-49eb-8c1d-cb5f24963f8e` "Hunter Ridge - Sour Cream" - REAL, in active use: 24 product_mapping rows, 27 active pod units.
- `285479a7-ea9f-4bb1-bc15-62c7581d7211` "Hunter Ridge - Sour Cream & Onion" - EMPTY shell: 0 mappings, 0 units.

CS: the physical product is "Sour Cream & Onion"; the name "Sour Cream" is the wrong label. Because the REFERENCED row is the bare "Sour Cream", the fix is NOT the PRD-062 merge direction. Correct fix:

- RENAME `4edc4fbb` -> "Hunter Ridge - Sour Cream & Onion" (keeps all 24 mappings + 27 units intact).
- DELETE the empty `285479a7` (zero references, so safe; verify zero everywhere first).
- If CS prefers to keep "Sour Cream" as the name, just delete the empty shell and skip the rename. Confirm direction before the rename.

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
