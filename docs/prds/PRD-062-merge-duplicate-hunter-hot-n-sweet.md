# PRD-062: Merge + delete duplicate boonz_product "Hunter - Hot N Sweet"

Status: Closed 2026-07-04 (CS). Reason: Hunter Hot N Sweet merge+delete completed 2026-06-26; reusable merge pattern documented and referenced by PRD-067 (CS decided 2026-07-04: keep "Hunter Ridge - Sour Cream" as survivor). Reopen by deleting this line.

Owner: CS
Date: 2026-06-25
Surface: Data merge on prod. Repoints references then deletes one boonz_products row. Touches protected entities (warehouse_inventory, pod_inventory, refill_dispatching) + product_mapping. Cody review mandatory; migration FILE first, apply on CS sign-off.
Governance: forward-only, idempotent, per-row counts before/after. No em dashes.

## Objective

Retire the duplicate product so it is gone everywhere, not just hidden. Merge ALL references of the duplicate into the real product, then delete the duplicate row.

- DUPLICATE (delete): `cca563ee-2e03-4de3-bad1-b17315b45864` — currently renamed "DO NOT USE - Hunter Hot N Sweet (dup of Hunter Ridge)" (was "Hunter - Hot N Sweet").
- KEEP (merge target): `8bc412d9-20f3-4432-a140-4e1f5360844f` — "Hunter Ridge - Hot N Sweet".

Known references on the duplicate (verified 2026-06-25): product_mapping 34, pod_inventory 14 (1 active unit), warehouse_inventory 1 (0 stock), refill_dispatching 50, sales 0. The interim rename already stopped PO confusion; this PRD does the clean removal.

## Steps

1. SCAN every table with a `boonz_product_id` column (information_schema) and count rows pointing at the duplicate. Do NOT assume only the tables above; find them all (refill_plan_output, sales_history, supplier_products, planogram if applicable via its own key, etc.).
2. For each referencing table, REPOINT `boonz_product_id` from the duplicate to the keep id, via the canonical writer where one exists; where the table has no writer, a scoped forward migration UPDATE is acceptable for this one-time merge with Cody review. CONFLICT HANDLING: where a unique constraint would collide (e.g. product_mapping unique on (pod_product_id, boonz_product_id, machine_id); pod_inventory / warehouse_inventory keys), do NOT create a duplicate, delete the duplicate-side row and keep the existing Hunter Ridge row. Preserve mix_weight/split_pct integrity on product_mapping (re-normalize if a merge changes a shelf's split).
3. The 1 active pod unit + the WH/dispatch history move to Hunter Ridge (no stock lost, no double count).
4. VERIFY the duplicate has ZERO references in every scanned table.
5. DELETE the boonz_products row `cca563ee...`.

## Rules

- Idempotent: re-running finds zero duplicate references and is a no-op.
- No stock change: total warehouse_stock + pod current_stock for the pair is identical before and after (just re-attributed to Hunter Ridge). Assert this.
- Per-row diff: show CS the count moved per table + the dedup count before the delete.
- Cody verdict required (Articles 1, 3, 12; touches warehouse_inventory / pod_inventory / refill_dispatching). Migration FILE only; apply on CS sign-off; STOP for CS before the DELETE.

## Acceptance

- Every table that referenced `cca563ee` now points at `8bc412d9` (or its dup-side row was a constraint collision and was removed).
- `boonz_products` no longer contains `cca563ee`.
- Sum of warehouse_stock + active pod stock for the pair is unchanged (conservation).
- "Hunter Ridge - Hot N Sweet" is the only Hunter Hot N Sweet product; the PO list shows one.

## Rollback note

The rename is already reversible (original name "Hunter - Hot N Sweet"). The merge is forward-only; if anything looks wrong in the dry-run counts, do not apply, fix the migration first.
