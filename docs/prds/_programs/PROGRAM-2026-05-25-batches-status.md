---
id: PROGRAM-2026-05-25-batches
parent: PROGRAM-2026-05-25
title: Batches 22May / 24May / 25May — status
status: Blocked
reason: Per program rule "STOP and ask CS before any DELETE or stock reduction"
  and "show CS the per-row diff before committing". Batches cannot proceed
  autonomously.
---

## Batch-22May — Status: Blocked-deferred

~30 rows of manual additions across NOVO, OMDBB, AMZ-1038/1057/1068/1029.
Plus one REMOVE: 2 pcs Organic Rice Milk Choc from OMDBB removed from WH.

**Why deferred:**

- The Organic Rice Milk Choc REMOVE is a stock reduction. Per program hard
  rule "DO NOT reduce stock unless fixing data or adding data", this needs
  explicit CS per-row sign-off.
- The ~30 additions are pod_inventory writes via canonical writer
  (`apply_inventory_correction` for WH side + `update_pod_inventory` or
  similar for pod side). Each row needs CS to verify the parse (machine
  short_id + product name + expiry + qty) against the doc bullet.
- Several rows include "planned_swap" entries (Be Kind → Barebells,
  Hot & Sweet → Himalayan Pink, McVities + Mars + Snickers wishlists) that
  are NOT pod adjustments but rather slot_lifecycle / driver_feedback writes.
  Those need a different canonical path that doesn't yet exist (see
  PRD-014-refill-pipeline cross-brand substitute).

**Pre-requisite for daylight apply:**

- CS parses the doc bullets into a structured CSV with columns
  `machine_short_id, boonz_product_name, expiry_date, qty, action_type,
source_kind, notes`.
- CS approves each row in batch.
- Apply via the canonical writer per row.

## Batch-24May — Status: Blocked-deferred (depends on schema change)

~50 rows of VOX cinema 0797 + 0795, IFLY refill, Magic Planet 0719 + 0715,
Activate 0817 (mixed source: some WH, some FROM OFFICE), Activate 0736
(FROM OFFICE), VOX Marecato 0798.

**Critical pre-requisite:**

- The `source_kind` provenance flag (CS-approved per program doc) must be
  added to either `po_additions.source_kind text` or
  `warehouse_inventory.source_kind text`. Dara picks the cleaner shape.
- This is a forward-only schema migration requiring Cody approval.
- Without this column, the FROM OFFICE rows have nowhere to record their
  provenance and the audit trail is incomplete.

**Why deferred:**

- Schema change → Cody approval required.
- Per-row CS sign-off required even after schema lands.
- The mixed-source Activate 0817 row in particular needs careful per-item
  tagging (some WH, some FROM OFFICE).

## Batch-25May — Status: Blocked-deferred (largest scope)

~80 pod_inventory adds for HUAWEI-2003 (~70 items) + MC-2004 (~50 items).
CS clarification: similar pattern to MCC ACTIVATE / VOXMM refills, NOT
an inventory_control_session.

**Why deferred:**

- Each row requires:
  1. Parse the doc line into `{machine, boonz_product_name, expiry, qty, action}`.
  2. Resolve `boonz_product_id` via `boonz_products` lookup.
  3. Resolve `pod_product_id` via `product_mapping` for the target machine.
  4. Show CS the per-row diff before committing.
- The doc explicitly lists ~120 line items across both machines.
  Resolving each name requires fuzzy-matching the doc spellings to
  canonical names (one example flagged in the doc: "Tamreemnnn" likely
  parse error for "Tamreen"). This needs CS confirmation per name.
- Some products may not exist in `product_mapping` for HUAWEI-2003 or
  MC-2004 yet — CS would need to seed mappings first.

**Pre-requisite for daylight apply:**

- CS parses the doc bullets into a structured CSV.
- Per-row verification of `boonz_product_id` and `pod_product_id` resolution.
- Then apply via the canonical pod_inventory writer in sequence.

## Recommended daylight approach for all 3 batches

1. CS structures the doc bullets into CSVs (one per batch) with the
   columns `machine_short_id, product_name, expiry, qty, action,
source_kind, planned_swap_partner, notes`.
2. CS reviews each row with a fresh agent session.
3. Agent applies row-by-row via canonical writers, with verification
   read-back per Plan Write Protocol.
4. After each batch, a memory entry is written summarising what was
   applied + any rows that needed CS-overridden mapping.

This is the only safe path consistent with the program hard rules. It
explicitly cannot happen overnight.
