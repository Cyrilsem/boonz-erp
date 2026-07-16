# DARA proposal — Warehouse availability: one canonical number + archive the dead, don't split live

**Author:** Dara (data architect) · **Date:** 2026-07-09 · **Status:** proposal → Cody review
**Entity:** `warehouse_inventory` (Appendix A protected; `status` is Article-6 manager-only)

---

## Design problem

`warehouse_inventory` holds one row per (product, warehouse, batch/expiry). Refills consume batches and
zero them; expiry flips batches to Expired; returns add rows. Nothing prunes, so the table is now **1,538
rows / 816 kB with only 205 live (Active + stock>0) — 86.7% dead** (Expired / Inactive / Removed / zero).
Worst products carry 30–39 rows with 0–4 live. **15 views** read the table. There is no single canonical
"how much of product X is dispatchable from warehouse Y" — each reader re-derives it, and against the dead
rows some mis-reduce to a zero/expired batch and return 0. That false-zero is what makes the engine emit
no dispatch line for stock that physically exists (the AMZ-1068 Activia case, bugs #2/#8). This is a
**correctness + clarity** problem, not a performance one.

## Recommendation (layered; P0 fixes the bug, P1 is hygiene)

### P0 — One canonical availability view (fixes the bug now, no data change)

```sql
CREATE OR REPLACE VIEW public.v_wh_available AS
SELECT
  wi.warehouse_id,
  wi.boonz_product_id,
  SUM(wi.warehouse_stock)                                   AS available_units,
  SUM(wi.consumer_stock)                                    AS consumer_units,
  MIN(wi.expiration_date) FILTER (WHERE wi.warehouse_stock > 0) AS earliest_expiry,
  COUNT(*) FILTER (WHERE wi.warehouse_stock > 0)            AS live_batches
FROM public.warehouse_inventory wi
WHERE wi.status = 'Active'
  AND COALESCE(wi.warehouse_stock, 0) > 0
  AND COALESCE(wi.quarantined, false) = false
  AND (wi.expiration_date IS NULL OR wi.expiration_date > CURRENT_DATE)   -- never offer expired
GROUP BY wi.warehouse_id, wi.boonz_product_id;
```

Then **every** availability reader (the dispatch/engine gate, `v_dispatch_availability`, `v_wh_pickable`,
the FE "no stock" check) consumes `v_wh_available` — one definition, deduped, dead rows can't leak in.
This alone kills the false-zero regardless of how many dead rows exist. **Deliberately NOT here:** the
near-expiry sell-through cutoff — keep that as an explicit, separate, tunable rule in the engine, not baked
into the availability number (so "expiring soon" and "no stock" never get conflated again).

### P0 — Partial index (the "clean + fast" win without splitting the table)

```sql
CREATE INDEX IF NOT EXISTS idx_wh_inv_live
  ON public.warehouse_inventory (boonz_product_id, warehouse_id)
  WHERE status = 'Active' AND warehouse_stock > 0;
-- Serves v_wh_available + every live-availability lookup. Indexes the 205 live rows, ignores the 1,333 dead.
-- (D5: index the access pattern. This is your "active table" — as an index, not a second table.)
```

### P1 — Archive the dead rows (this is your instinct, done safely)

Not a live active/inactive split (dual-write on a governed column). Instead a one-directional **archive**:

```sql
CREATE TABLE IF NOT EXISTS public.warehouse_inventory_archive (LIKE public.warehouse_inventory INCLUDING ALL);
-- nightly pg_cron: move terminal rows OUT of the hot table into the archive.
--   move WHERE status IN ('Expired','Removed') OR (status='Inactive' AND warehouse_stock=0)
--   INSERT ... DELETE ... in one txn, logged to warehouse_inventory_audit_log.
CREATE OR REPLACE VIEW public.v_warehouse_inventory_all AS
  SELECT * FROM public.warehouse_inventory
  UNION ALL SELECT * FROM public.warehouse_inventory_archive;   -- history/audit readers use this
```

Effect: `warehouse_inventory` drifts toward "live working set" (~205 rows), giving you the clean, small,
unconfusing active table you wanted — **without** rewriting the 15 views (they keep reading
`warehouse_inventory`, now mostly-live) and **without** dual-writing `status` (the archive job moves rows
that are _already_ terminal, so it never flips a governed status — Article 6 stays intact).

### P1 — Stop the regrowth at the write path

Fragmentation regrows because refills don't consolidate and expiry doesn't archive. Fold into the refill
consume-path + the existing `auto_expire_old_warehouse_stock` cron: FEFO-consume then set `warehouse_stock=0`

- status→Inactive on depletion; expiry flips to Expired; nightly archive sweeps both. (This is a function-body
  change → Cody + implementer, separate from this schema proposal.)

## Tradeoffs and alternatives

- **CS's proposal — two live tables (active / inactive), dual-write on status change.** Rejected. ~0 perf
  gain at 816 kB; forces a write to a second table on every Article-6 `status` transition (governance
  headache); 15 dependent views must be rewritten or a compatibility UNION view maintained forever;
  cross-table joins for every history/audit query. High blast radius on a protected entity for no
  correctness benefit the canonical view doesn't already deliver. **When this would be right:** if the
  table were 50M+ rows (D7) — then physical separation / partitioning earns its keep. It isn't.
- **Range-partition by month.** Rejected — same reasoning; partitioning is a >50M-row tool (D7), overkill here.
- **Materialized view for availability.** Rejected — the live set is tiny; a plain view is always-fresh and
  needs no refresh job. Reach for MATVIEW only if a reader proves too slow (it won't at this scale).

## Cody handoff checklist

- **Article 2/3 (RLS/read):** `v_wh_available` and `v_warehouse_inventory_all` are read-only views over a
  protected entity — confirm SELECT exposure is acceptable and no write path is introduced.
- **Article 6 (sensitive `status`):** the archive job must only MOVE rows already in a terminal status; it
  must NOT set/flip `status`. Confirm.
- **Article 4/12 (audit):** archive moves logged to `warehouse_inventory_audit_log`; confirm the trigger
  fires on the DELETE-from-hot / INSERT-to-archive.
- **Article 14 (protected entity):** `warehouse_inventory_archive` is a new protected entity — add to
  Appendix A in the same migration that creates it.
- **Article 15:** if "terminal-row archival of a protected entity" isn't covered, surface as an amendment.

**Sequencing:** ship P0 (view + index + repoint readers) first — it fixes the dispatch false-zero on its
own. P1 (archive + write-path) is hygiene that stops the dead rows accumulating; it can follow.
