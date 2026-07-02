# PRD-016 — Return / transfer guardrails (3 bugs from 19-21 May)

**Status:** ✅ SHIPPED 2026-05-31 (all 3 guardrails live; build details + verification in PRD-016B).
Designed + Cody-reviewed 2026-05-31; CS chose **Path A** for guardrail 3. Guardrails 1 & 2
shipped WARN-first (escalate to BLOCK when FE wiring lands). FE split-by-variant → Stax STAX-2026-05-31-01.

**Source incidents:** Refill Update Doc "System Bugs Summary" (19/05 IFLY M2M,
21/05 OMDCW-1021 Hunter return, 21/05 MCC WH phantoms).

---

## Root cause (common to all three)

The Remove / return path credits and auto-creates `warehouse_inventory` rows with
under-validated **variant**, **destination**, and **lineage**. Evidence:

- `return_dispatch_line` ELSE branch (no matching Active batch found) does
  `INSERT INTO warehouse_inventory (... status='Active', batch_id='REMOVE-RETURN-<date>' ...)`.
- The function stamps `app.provenance_reason='dispatch_return'` (trusted) ONCE at
  the top, so the create-new-batch ELSE branch also gets the trusted value and the
  generated `quarantined` column leaves it `false` → row goes live + pickable.

### Bug A — 19/05 IFLY Barebells 12pcs → WH instead of AMZ

`IFLYMCC-1024` row: action=Remove, qty 12, Barebells - Creamy Crisp,
`is_m2m=false`, no partner, `[TRUCK-TRANSFER]` comment, from_wh=WH_MCC. Entered as
a one-directional Remove instead of `swap_between_machines`. Return logic credited
12 to WH_MCC; AMZ never got them. Closed 30/05 (retained at WH). **Prevention only.**

### Bug B — 21/05 OMDCW-1021 Hunter Truffle shows as Hunter Sea Salt

Return row: pod="Hunter" (multi-variant pod), boonz defaulted to "Hunter - Sea
Salted". Return flow has no variant-reassign; "split by variant" errored.
`record_variant_correction` + `variant_action_log` exist but are not wired into
the return path. **Open.** (Stax ticket STAX-2026-05-31-01.)

### Bug C — 21/05 MCC WH phantoms

4 WH_MCC rows with no PO lineage, born from the ELSE branch (batch ids
`RETURN-2026-05-10`, `REMOVE-RECEIVE-2026-05-13`), all pre-PRD-003. Perrier (12)
and Organic Larder are `quarantined=true` (already excluded from refill reads);
the two Hunters were zeroed via `manual_adjust`. PRD-003 (2026-05-21) built the
containment substrate; the remaining hole is the trusted-provenance stamp on the
create-new-batch branch.

---

## Cody verdict (2026-05-31)

⚠️ Approve with revisions. Articles 1, 4, 6, 7, 12, 14.

- Art 6 ✅ status untouched (only provenance + generated quarantined).
- Art 14 ✅ no parallel table.
- Art 12 ⚠️ generated column needs drop/re-add (no ALTER for generated exprs).
  Dependents MUST be dropped + recreated in the same migration:
  index `idx_wh_inv_quarantined` AND view `v_wh_inventory_provenance`.
- Art 4 ⚠️ the return/receive RPC-body change is a separate canonical-writer
  rewrite → its own migration + its own Cody review + CS green light.
- Table is 973 rows; rewrite lock negligible.

---

## Guardrail 1 — M2M-as-Remove (logic-layer, no schema change)

BEFORE-INSERT trigger / RPC validation on `refill_dispatching`: reject (or
`monitoring_alerts`-flag) an `action='Remove'` row whose comment carries transfer
intent (`%[TRUCK-TRANSFER]%`) but `is_m2m=false AND m2m_partner_id IS NULL`. Steer
to `swap_between_machines`. Handoff: Cody (trigger body) + Stax (FE routing).

## Guardrail 2 — return variant correction (logic-layer, no schema change)

Wire `record_variant_correction` into the return RPC; require an explicit boonz
variant when the pod_product maps to >1 active boonz variant before crediting WH.
Handoff: Cody (RPC body) + Stax (split-by-variant UI that errored).

## Guardrail 3 — phantom containment (Path A, DDL)

### STATUS 2026-05-31

- Migration 1 (DDL) APPLIED as `phaseF_prd016_quarantine_unverified_return`. **Learning beyond Cody's review:** the generated `quarantined` column had a THIRD dependent not caught in review — materialized view `mv_wh_inventory_provenance` (passthrough of the view, indexes `mv_wh_provenance_pk` UNIQUE + `mv_wh_provenance_quarantined`). The migration now drops/recreates MV + view + index. Verified: 973 rows, 870 quarantined (pre-existing NULL/pre-migration), 0 `dispatch_return_unverified` yet.
- Migration 2 (RPC ELSE-branch provenance) — ✅ APPLIED 2026-05-31 as `phaseF_prd016_unverified_return_provenance`. Verbatim CREATE OR REPLACE of return_dispatch_line + receive_dispatch_line; unverified stamp + trusted restore on each create-new-batch ELSE INSERT. Cody ✅ (separate review). Verified dry: no-match → quarantined, match → trusted.
- Guardrail 1 (M2M-as-Remove trigger) — ✅ APPLIED as `phaseF_prd016_guardrail1_m2m_as_remove` (WARN posture, `flag_remove_with_transfer_intent`). Guardrail 2 (variant correction wiring) — ✅ APPLIED as `phaseF_prd016_guardrail2_return_variant_correction` (WARN posture, NEW trigger `flag_multivariant_return_without_correction`; FE → Stax STAX-2026-05-31-01). See PRD-016B DONE CRITERIA + CHANGELOG for verification.

### Migration 1 (DDL) — `phaseF_prd016_quarantine_unverified_return` (APPLIED)

```sql
BEGIN;

-- 1. Drop dependents (view + partial index) so DROP COLUMN can proceed.
DROP VIEW IF EXISTS public.v_wh_inventory_provenance;
DROP INDEX IF EXISTS public.idx_wh_inv_quarantined;

-- 2. Extend provenance vocabulary with the unverified-return value.
ALTER TABLE public.warehouse_inventory DROP CONSTRAINT wh_provenance_reason_enum;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT wh_provenance_reason_enum CHECK (
  provenance_reason IS NULL OR provenance_reason IN (
    'po_receive','dispatch_return','dispatch_pack','dispatch_receive',
    'm2m_return','wh_transfer','manual_adjust','snapshot','status_flip',
    'unknown_pre_migration',
    'dispatch_return_unverified'
  ));

-- 3. Redefine the generated quarantine column to distrust the new value.
ALTER TABLE public.warehouse_inventory DROP COLUMN quarantined;
ALTER TABLE public.warehouse_inventory ADD COLUMN quarantined boolean
  GENERATED ALWAYS AS (
    provenance_reason IS NULL
    OR provenance_reason IN ('unknown_pre_migration','dispatch_return_unverified')
  ) STORED;

-- 4. Recreate the partial index (needs-review screen).
CREATE INDEX idx_wh_inv_quarantined
  ON public.warehouse_inventory USING btree (warehouse_id, boonz_product_id)
  WHERE (quarantined = true);

-- 5. Recreate the provenance view (security_invoker per PRD-003).
CREATE VIEW public.v_wh_inventory_provenance WITH (security_invoker = true) AS
 SELECT wi.wh_inventory_id, wi.warehouse_id, w.name AS warehouse_name,
        wi.boonz_product_id, bp.boonz_product_name AS product_name,
        wi.warehouse_stock, wi.consumer_stock, wi.expiration_date, wi.batch_id,
        wi.status, wi.provenance_reason, wi.source_event_id, wi.quarantined,
        (SELECT ial.audited_at FROM inventory_audit_log ial
          WHERE ial.wh_inventory_id = wi.wh_inventory_id
          ORDER BY ial.audited_at DESC NULLS LAST LIMIT 1) AS last_audit_at,
        (SELECT ial.reason FROM inventory_audit_log ial
          WHERE ial.wh_inventory_id = wi.wh_inventory_id
          ORDER BY ial.audited_at DESC NULLS LAST LIMIT 1) AS last_audit_reason
   FROM warehouse_inventory wi
   LEFT JOIN warehouses w ON w.warehouse_id = wi.warehouse_id
   LEFT JOIN boonz_products bp ON bp.product_id = wi.boonz_product_id;

COMMIT;
```

### Migration 2 (RPC bodies, SEPARATE Cody review) — `phaseF_prd016_unverified_return_provenance`

In BOTH `return_dispatch_line` and `receive_dispatch_line`: in the create-new-batch
ELSE branch only (the `IF NOT FOUND` insert), before the `INSERT INTO
warehouse_inventory`, re-issue:

```sql
PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
```

Merge-into-existing-batch path keeps `'dispatch_return'` / `'dispatch_receive'`.
Net: a return landing on a real received batch is trusted; a return inventing a
batch lands quarantined and on the needs-review screen.

### Verify after apply

- `SELECT quarantined, provenance_reason FROM warehouse_inventory LIMIT 5;`
- Re-confirm `idx_wh_inv_quarantined` and `v_wh_inventory_provenance` exist.
- Smoke: simulate a return for a product with no matching WH batch → row should be
  `quarantined=true, provenance_reason='dispatch_return_unverified'`.

---

_Generated 2026-05-31. Build after the data tracks. No writes applied yet._
