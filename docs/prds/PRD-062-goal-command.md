# Claude Code /goal Command - PRD-062 (merge + delete duplicate product)

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Migration FILE first; STOP for CS before applying the delete. No em dashes.

```
/goal Implement PRD-062 (docs/prds/PRD-062-merge-duplicate-hunter-hot-n-sweet.md); read it first. Merge the duplicate product into the real one, then delete it. DUPLICATE (delete) = cca563ee-2e03-4de3-bad1-b17315b45864 (renamed "DO NOT USE - Hunter Hot N Sweet (dup of Hunter Ridge)"). KEEP = 8bc412d9-20f3-4432-a140-4e1f5360844f ("Hunter Ridge - Hot N Sweet").

RULES
- Forward-only migration FILE; apply nothing until CS signs off; STOP for CS before the DELETE.
- Cody verdict required (touches warehouse_inventory / pod_inventory / refill_dispatching - Articles 1,3,12).
- Idempotent: re-running finds zero duplicate references and no-ops.
- CONSERVATION: total warehouse_stock + active pod current_stock for the pair must be identical before and after (only re-attributed to KEEP). Assert it; if it would change, stop.
- Per-row diff: report the count moved per table + the dedup-collision count before the DELETE.

STEPS
1. SCAN information_schema for EVERY table with a boonz_product_id column; count rows pointing at the duplicate (known: product_mapping 34, pod_inventory 14 incl 1 active unit, warehouse_inventory 1, refill_dispatching 50, sales 0 - but find them ALL).
2. For each table, REPOINT boonz_product_id duplicate -> KEEP. CONFLICT HANDLING: where a unique key would collide (product_mapping unique (pod_product_id, boonz_product_id, machine_id); pod_inventory / warehouse_inventory keys), do NOT create a duplicate - delete the duplicate-side row, keep the existing KEEP row. Re-normalize product_mapping mix_weight/split_pct if a shelf's split changes.
3. VERIFY the duplicate has ZERO references everywhere.
4. DELETE boonz_products cca563ee.

Show me the per-table move/dedup counts + the conservation assert + Cody verdict before applying. The rename is already done and reversible; this is the clean removal.
```

PRD: `boonz-erp/docs/prds/PRD-062-merge-duplicate-hunter-hot-n-sweet.md`.
