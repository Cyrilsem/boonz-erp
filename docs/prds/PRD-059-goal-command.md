/goal PRD-059: expiry batch hygiene so Stock Snapshot card counts match the per-machine drawer, no data loss. Spec: boonz-erp/docs/prds/PRD-059-expiry-batch-hygiene.md. MODE AUTO, STOP for CS before EVERY write (show the row list first).

CONTEXT (live, eizcexopcuoycuosittm 2026-06-24): card expiry = v_machine_expiry_summary -> v_machine_expiry_batches -> Active pod_inventory by boonz_product_id, with NO shelf link and NO check the product is still on the machine. NULL-shelf Active batches via product_mapping (status='Active', machine row over is_global_default): RESOLVE 132 batches/481u, HIGHLIGHT 138/579u, NO ACTIVE MAPPING 23/109u. Plus 1,878 Inactive rows/7,646u (293 expired) lingering. Earlier on-machine check used slot_lifecycle.is_current which misses physically-present products (WAVEMAKER Coca Cola Zero) -> THIS PRD uses v_live_shelf_stock (machine_id+pod_product_id, is_enabled), matching the drawer.

RESOLUTION RULE: for each Active pod_inventory batch with shelf_id IS NULL: map boonz_product_id -> pod_product_id via product_mapping (Active). Then check v_live_shelf_stock for machine_id+pod_product_id+is_enabled. PRESENT -> RESOLVE (backfill shelf_id via aisle_code/slot_name -> shelf_configurations). ABSENT -> HIGHLIGHT. No Active mapping -> mark Inactive.

PRE: git pull --rebase main; branch feat/prd-059-expiry-batch-hygiene.

BUILD (phased; STOP with the row list before each write):
WS1 Dara: implement resolution rule on v_live_shelf_stock; output RESOLVE/HIGHLIGHT/NO-MAPPING lists. Read-only.
WS2 RESOLVE: backfill pod_inventory.shelf_id NULL->resolved shelf. Pointer backfill only (NULL->value), zero stock change. Show list first.
WS3 NO ACTIVE MAPPING: set pod_inventory.status='Inactive' for the 23 batches. Status transition, not delete. Show list.
WS4 HIGHLIGHT orphans: status='Removed/Expired', removal_reason='orphan_not_on_machine', after CS signs off. No DELETE.
WS5 Inactive cleanup: transition the 1,878 Inactive rows to status='Removed/Expired', removal_reason='inactive_cleanup'; current_stock preserved, NOT zeroed/deleted. Show aggregate + list first.
WS6 Stax FE drawer: (a) add "Unassigned/orphan expiry" section so a header count is never invisible; (b) populate empty Exp Qty per slot from nearest-expiry batch. Verify 375px, axe clean.

TEST (all pass; STOP on any failure):
T1 after WS2, every RESOLVE batch shows in its drawer slot with Exp Qty; machine header expired/expiring == sum of in-drawer expiry.
T2 after WS3/4/5, v_machine_expiry_summary counts only Active AND (shelf-mapped OR orphan-section) batches.
T3 no row deleted; every WS3/4/5 row is a reversible status transition; rows in == rows out.
T4 resolution parity vs drawer (WAVEMAKER Coca Cola Zero classifies correctly).
T5 engine_add_pod + engine_swap_pod byte-identical; swaps_enabled false.

CLOSE: update CHANGELOG.md, MIGRATIONS_REGISTRY.md, METRICS_REGISTRY.md; set PRD-059 per-WS status with migration names + FE commit.

HARD SAFETY: pod_inventory protected (Cody review, Hard Rule 6). NO DELETE, no stock zeroing, no DROP - status transitions + NULL->value backfills only, each with a CS-reviewed row list. Forward-only; rebase --autostash; engine output byte-identical; do NOT push to main without explicit go-ahead; pause for CS before EVERY write.
