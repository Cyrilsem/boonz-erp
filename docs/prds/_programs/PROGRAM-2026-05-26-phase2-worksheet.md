# PROGRAM-2026-05-26 — Phase 2 daylight worksheet

**Generated:** 2026-05-30 from live prod query.
**Use:** CS daylight session — clear the 10 M2M orphans + 79 over-allocated
rows by reviewing and approving each row, then pasting the suggested RPC
call.

All RPC infrastructure is live (`cancel_dispatch_line`,
`repair_orphan_internal_transfer`) — Cody-approved 2026-05-30, applied via
migration `phaseG_followup_prd014_inventory_phase2_writers`.

---

## Section A — 10 M2M orphans

**Live state 2026-05-30:** 10 rows match `source_origin='internal_transfer'
AND m2m_transfer_id IS NULL AND action='Remove'`.

Many of these have destination encoded in the `comment` field (parsed in
the "Suggested destination" column). For rows where the comment is just
"[TRUCK-TRANSFER — do not debit WH]" with no explicit destination, CS
must look at the field notes / trip logs to identify where the product
actually landed.

| #   | dispatch_id                            | source         | product                                   | qty | date       | expiry     | comment                                                                        | Suggested destination                                                                                           |
| --- | -------------------------------------- | -------------- | ----------------------------------------- | --- | ---------- | ---------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| 1   | `16604bd2-9fc7-4b2e-9ce1-9db3edd6b343` | MINDSHARE-1009 | Organic Larder - Rice Cake Milk Chocolate | 3   | 2026-05-20 | —          | "Removed from Mindshare → transferred to WPP"                                  | **WPP-1002-4300-O1**                                                                                            |
| 2   | `2c43a829-8ac0-498d-b0e4-e55f04ab16e2` | MINDSHARE-1009 | Nutella - Biscuit T12                     | 5   | 2026-05-20 | —          | "Removed from Mindshare → transferred to AMZ-3003"                             | **AMZ-1029-3003-O1** (likely)                                                                                   |
| 3   | `e29a8abe-a9fd-411d-88e4-c5d70f868114` | IFLYMCC-1024   | Vitamin Well - Care                       | 3   | 2026-05-19 | 2026-06-07 | "[TRUCK-TRANSFER to ACTIVATEMCC-1037 A05 — do not debit WH]"                   | **ACTIVATEMCC-1037-0000-L0**                                                                                    |
| 4   | `a40a2d64-a87f-4371-8388-b285646ec72a` | IFLYMCC-1024   | Vitamin Well - Reload                     | 3   | 2026-05-19 | 2026-06-14 | "[TRUCK-TRANSFER to ACTIVATEMCC-1037 A07 + VOXMCC-1005 A10 — do not debit WH]" | **SPLIT** — needs two repair rows OR cancel + manual write                                                      |
| 5   | `4b73d9ba-a939-4f79-81be-2bfa7dcc24b8` | IFLYMCC-1024   | Vitamin Well - Upgrade                    | 3   | 2026-05-19 | 2026-06-21 | "[TRUCK-TRANSFER to ACTIVATEMCC-1037 A05 — do not debit WH]"                   | **ACTIVATEMCC-1037-0000-L0**                                                                                    |
| 6   | `68521f50-1cc3-434f-9e93-6035b9844176` | IFLYMCC-1024   | Popit - Orange Squeeze                    | 6   | 2026-05-19 | —          | "[TRUCK-TRANSFER — do not debit WH]"                                           | **CS to identify**                                                                                              |
| 7   | `0d67ee16-2427-411c-a23e-fd513ff9b2b3` | IFLYMCC-1024   | Barebells - Creamy Crisp                  | 12  | 2026-05-19 | —          | "[TRUCK-TRANSFER — do not debit WH]"                                           | **CS to identify** (this is the IFLY-1024 → AMZ case from PRD-014-inventory RCA — CS knows the AMZ destination) |
| 8   | `3fe21c4a-d79d-44f5-b9c3-064aa498bdb3` | IFLYMCC-1024   | Popit - Lemon & Lime                      | 6   | 2026-05-19 | —          | "[TRUCK-TRANSFER — do not debit WH]"                                           | **CS to identify**                                                                                              |
| 9   | `b3346b9f-03ee-4d4f-be00-bb312c2964dc` | IFLYMCC-1024   | Popit - Original Cola                     | 6   | 2026-05-19 | —          | "[TRUCK-TRANSFER — do not debit WH]"                                           | **CS to identify**                                                                                              |
| 10  | `62612df7-9233-4709-a22d-79e3476e4780` | IFLYMCC-1024   | Vitamin Well - Antioxidant                | 3   | 2026-05-19 | 2026-06-28 | "[TRUCK-TRANSFER to ACTIVATEMCC-1037 A07 + VOXMCC-1005 A10 — do not debit WH]" | **SPLIT** — needs two repair rows OR cancel + manual write                                                      |

### Resolution template (per orphan)

```sql
-- For unambiguous destination:
SELECT public.repair_orphan_internal_transfer(
  '<orphan_dispatch_id>'::uuid,
  '<destination_machine_id>'::uuid,
  '<reason text, >=10 chars>'
);

-- Machine ID lookup helper:
SELECT machine_id, official_name FROM public.machines
WHERE official_name IN ('WPP-1002-4300-O1','AMZ-1029-3003-O1','ACTIVATEMCC-1037-0000-L0');

-- For SPLIT cases (rows 4 + 10): the existing RPC only writes ONE Add New.
-- Options:
--   (a) Cancel the orphan via cancel_dispatch_line (use 'split_transfer_manual_followup' reason)
--       then have CS manually log the two destination receives via separate flow.
--   (b) Pick the primary destination, repair to that. The second destination's
--       receive becomes a separate inventory_control_attempt for that machine.
--   Recommendation: (b) — repair to the larger-quantity destination first.
```

---

## Section B — 79 over-allocated rows

**Live state 2026-05-30:** 79 rows match `packed=true AND
from_wh_inventory_id IS NULL AND action IN ('Refill','Add New','Add') AND
source_origin <> 'vox_at_venue' AND dispatch_date 2026-05-19..23 AND NOT
cancelled`.

Top groupings by product + date (full per-row list available via the
query in Section D):

### 2026-05-19 (10 rows)

- Barebells White Almond Chocolate (1×2u → OMDCW-1021)
- Barebells White Chocolate (1×1u → OMDCW-1021)
- Evian Regular (3×24u → ACTIVATEMCC-1037) **24u shortfall** — likely VOX-sourced, should have been tagged
- Pocari Sweat Regular (1×7u → ACTIVATE-2005) — likely VOX-sourced
- TEST products at WH2_2006 (4×—) — **CANCEL these test rows**
- Vitamin Well Care (2×2u → ACTIVATEMCC-1037)
- Vitamin Well Hydrate (3×4u → ACTIVATEMCC-1037, VOXMCC-1005)

### 2026-05-20 (33 rows — largest day)

Dominated by AMZ-1029 / AMZ-1038 / AMZ-1057 / AMZ-1068:

- Barebells variants (10 rows across 6 SKUs)
- Vitamin Well variants (9 rows across 4 SKUs) — WH was empty per PRD-013 finding
- Coca Cola Regular (3×18u) — VOX-sourced product going through WH path = engine Bug A
- M&M, Bounty, Kinder Bueno, Nutella — Boonz-supplied real shortfalls
- Organic Larder Rice Cake Milk Chocolate (4×7u across AMZ + WPP) — note: 2u of this was REMOVED from OMDBB to AMZ-1038 per the 22-May refill update doc (Batch-22May edge case)

### 2026-05-21 (8 rows)

- Barebells Cookies and Caramel (4×5u across ADDMIND/NOOK/USH/VML)
- Barebells Creamy Crisp (1×2u → VML)
- Hunter Hot N Sweet (2×2u)
- Dubai Popcorn (1×1u)

### 2026-05-22 (13 rows)

- Pepsi Black (1×4u → NOVO-1023) — **VOX-sourced** at NOVO? Confirm; if VOX, tag instead of cancel
- Pepsi Regular (1×3u → NOVO-1023) — **VOX-sourced** at NOVO? Same
- Krambals Creamy Cheese (1×1u → NOVO-1023) — non-VOX, real shortfall
- Vitamin Well variants (4×6u)
- Hunter variants (2×2u → OMDBB-1020)
- Bounty Regular (1×3u → AMZ-1038)
- Sabahoo Chocolate (1×4u → AMZ-1068)
- Smart Gourmet (2×4u)
- Al Ain Water (1×4u → AMZ-1057) — VOX-sourced product
- Activia Mix & Go (1×1u → OMDBB)
- Barebells Creamy Crisp (1×1u → OMDBB)
- Organic Larder Rice Cake Milk Chocolate (1×1u → AMZ-1038) — relates to the Batch-22May REMOVE

### 2026-05-23 (15 rows — pull via query below)

### Resolution template (per row)

Three paths per the program doc:

**1. CANCEL** (the WH never had stock + the product physically didn't land):

```sql
SELECT public.cancel_dispatch_line(
  '<dispatch_id>'::uuid,
  'WH out of stock during 2026-05-XX cycle; row over-allocated by engine bug B (no allocation tally); product not delivered to machine. See PROGRAM-2026-05-26 Phase 2.'
);
```

**2. EXTERNAL SOURCE** (product landed at machine from a non-WH source —
e.g. VOX cinema supplied, driver brought from home stock):

```sql
SELECT public.mark_dispatch_vox_sourced(
  '<dispatch_id>'::uuid,
  'Product VOX-sourced at venue; WH not debited. See PROGRAM-2026-05-26 Phase 2.'
);
-- Use for: Pepsi/Aquafina/Ice Tea/M&M Bags/Maltesers/Fade Fit/
-- Chocolate Bar/Skittles/Soft Drinks Mix at VOX/IFLY/MagicPlanet/Activate
-- machines.
```

**3. TRIM** (WH had some stock, just not enough — re-pin to actual qty
via repair_unbound_dispatch with the trimmed quantity. NOTE: existing
repair_unbound_dispatch binds full qty; trimming requires CS to first
edit the dispatch quantity then repair. Existing edit path is via the
inventory FE manager affordance.):

```sql
-- Step 1: edit qty down on the dispatch row to actual delivered qty
-- via the existing pack drawer.
-- Step 2: then call repair_unbound_dispatch with the now-matching qty.
```

### Recommended fast-path classification

CS can bulk-classify by group:

| Pattern                                                           | Suggested action                                           | Count  |
| ----------------------------------------------------------------- | ---------------------------------------------------------- | ------ |
| TEST products at WH2_2006                                         | **CANCEL**                                                 | 4      |
| VOX-sourced products at VOX/IFLY/Activate/MagicPlanet venues      | **mark_dispatch_vox_sourced**                              | ~10-15 |
| Vitamin Well variants (all Inactive in WH per PRD-013)            | **CANCEL**                                                 | ~25    |
| Barebells variants at AMZ-1029 cluster (WH depleted)              | **CANCEL**                                                 | ~10    |
| Organic Larder Rice Cake at AMZ-1038 22-May                       | LINKED to Batch-22May REMOVE — repair via Batch-22May flow | 1      |
| Pepsi Black/Regular at NOVO 22-May                                | Confirm VOX-status; CANCEL or mark_vox                     | 2      |
| Other Boonz-supplied real shortfalls (Bounty, M&M, Nutella, etc.) | **CANCEL** with reason "WH out of stock"                   | ~20    |

---

## Section C — Pre-built per-row SQL for the over-allocated rows

```sql
-- Full per-row list — paste this query, classify each row by adding a
-- 'classification' column manually in a spreadsheet, then run the matching
-- RPC call per row.

SELECT rd.dispatch_id,
       m.official_name AS machine,
       bp.boonz_product_name AS product,
       rd.quantity::int AS planned_qty,
       rd.dispatch_date,
       COALESCE(rd.expiry_date::text, '') AS expiry,
       COALESCE(rd.comment, '') AS comment,
       m.venue_group
FROM refill_dispatching rd
JOIN machines m ON m.machine_id = rd.machine_id
JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
WHERE rd.packed = true
  AND rd.from_wh_inventory_id IS NULL
  AND rd.action IN ('Refill','Add New','Add')
  AND COALESCE(rd.source_origin, 'warehouse'::source_origin_enum) <> 'vox_at_venue'::source_origin_enum
  AND rd.dispatch_date BETWEEN '2026-05-19' AND '2026-05-23'
  AND COALESCE(rd.cancelled, false) = false
ORDER BY rd.dispatch_date, m.official_name, bp.boonz_product_name;
```

---

## Section D — Verification queries

After each pass, re-run these counts to confirm progress:

```sql
-- M2M orphans remaining:
SELECT COUNT(*) FROM refill_dispatching
WHERE source_origin = 'internal_transfer'::source_origin_enum
  AND m2m_transfer_id IS NULL
  AND action = 'Remove';
-- Target: 0 (or all remaining rows in the SPLIT category with documented reason)

-- Over-allocated rows remaining:
SELECT COUNT(*) FROM refill_dispatching
WHERE packed = true
  AND from_wh_inventory_id IS NULL
  AND action IN ('Refill','Add New','Add')
  AND COALESCE(source_origin, 'warehouse'::source_origin_enum) <> 'vox_at_venue'::source_origin_enum
  AND dispatch_date BETWEEN '2026-05-19' AND '2026-05-23'
  AND COALESCE(cancelled, false) = false;
-- Target: 0

-- Cancellations made this session:
SELECT COUNT(*) FILTER (WHERE cancelled = true AND cancelled_at::date = CURRENT_DATE) AS cancelled_today,
       SUM(quantity) FILTER (WHERE cancelled = true AND cancelled_at::date = CURRENT_DATE)::int AS qty_cancelled_today
FROM refill_dispatching;

-- VOX-sourced flips made this session:
SELECT COUNT(*) FROM refill_dispatching
WHERE source_origin = 'vox_at_venue'::source_origin_enum
  AND updated_at::date = CURRENT_DATE;
```

---

## Section E — Mark Phase 2 Done

After all 10 orphans and 79 over-allocated rows are resolved:

1. Update `docs/prds/inventory/PRD-014-m2m-routing-fix-and-ifly-rca.md`
   frontmatter from `Phase1+2+3-infra-Done-per-row-repairs-pending-CS`
   to `Done`. Add `phase3_per_row_completed_at: 2026-XX-XX`.
2. Update `PROGRAM-2026-05-26-refill-data-reconciliation.md` frontmatter
   from `Partial-Phase3-Done-rest-Blocked` to reflect Phase 2 Done.
3. Update `MEMORY.md` with the actual counts cancelled / paired / VOX-flipped.
4. Commit with message
   `feat(phase-g-followup): PROGRAM-2026-05-26 Phase 2 — Done (NN orphans paired, NN over-allocated resolved)`.
