# PRD-073 Execution Log - Eligibility hardening + grade-weighted empty/low-fill urgency

Run 2026-07-04, AUTO mode. All hard gates held throughout:
engine_add_pod md5 `ca074e575511da124605783b726c8584`, engine_swap_pod md5
`90f26896ba7e0a7099fa689e73eaab91`, pick_machines_for_refill md5
`48cc18449e003494ad9360c5aa6780a0` - identical before and after both migrations.
Every write preceded by a rolled-back BEGIN..ROLLBACK proof. All knobs in
pick_urgency_params (single row; ADD COLUMN defaults filled it).

## Pre-existing data fix (from chat, 2026-07-03) - recorded per goal

`UPDATE machines SET adyen_inventory_in_store='Live' WHERE adyen_inventory_in_store='true' AND status='Active'`
(12 rows, all previously 'true'): AMZ-1029, AMZ-1038, AMZ-1057, AMZ-1068, NOVO-1023,
NISSAN-0804, ALJLT-1015, MINDSHARE-1009, ACTIVATE-2005, ACTIVATEMCC-1037, IFLYMCC-1024,
MPMCC-1054. Verified then: AMZ-1038 + AMZ-1029 went P1 with correct hero grades.

## WS-A - eligibility hardening (SHIPPED)

**Writer found: NOT n8n.** The machines page (`src/app/(app)/app/machines/page.tsx`) typed
the TEXT column as `boolean | null` and rendered an EditableBoolField toggle, saved via
direct `.update(diff)` - toggling wrote literal 'true'. Fixed: constrained EditableSelect
(ADYEN_INVENTORY_OPTIONS), type corrected; pods page display truthiness fixed
(`'false'` no longer renders as a checkmark; check is startsWith('Live')). DB-side scan:
only `repurpose_machine` touches the column (legitimate). No n8n/edge writer exists.

- `prd073b_wsa_adyen_inventory_enum_and_drift_monitor` APPLIED: CHECK
  `machines_adyen_inventory_in_store_enum` (NOT VALID -> VALIDATE; proof: validates all
  existing rows, rejects 'true') + `v_machine_eligibility_drift` monitor.
- **Monitor finding (SKIP-and-HIGHLIGHT):** drift is NOT zero - 4 rows:
  - ACTIVATE-2005-0000-W0, IFLYMCC-1024-0000-W0, MPMCC-1054-0000-M0: 'Live' but
    `repurposed_at` NOT NULL while Active -> `is_eligible_machine` false. This is the
    known PRD-028 "repurposed-but-Active" carry-forward; 3 of the 12 chat-fixed machines
    are STILL grading-blind for this second reason. `repurposed_at` is a sensitive column
    (repurpose_machine only) - NOT mutated unattended. **CS decision needed:** clear
    repurposed_at on these 3 (they are live identities) or repurpose them properly.
  - MPMCC-1058-0000-R0: 'Pending Setup' - legitimately not live; correct monitor listing.

## WS-B - grade-weighted empty/low-fill urgency (SHIPPED)

`prd073b_wsb_v_machine_priority_v2_empty_lowfill` APPLIED. New pick_urgency_params
columns (defaults): empty_wt_a 1.0 / empty_wt_b 0.7 / empty_wt_c 0.45 / empty_wt_d 0.25,
w_empty 0.9, w_lowfill 0.5, low_fill_pct_floor 25, p1_empty_ab_min 1. View v2: is_empty /
is_low at v_shelf_sales_identity grain (enabled non-broken upstream; denominator = graded
identities), s_empty / s_lowfill terms in the blend (all 5 occurrences), reasons
empty_shelves / low_fill_sellers / hero_shelf_empty, P1 escalation on empty A/B count.
Appended output cols: s_empty, s_lowfill, empty_ab_count. Preserved v1 quirk deliberately:
zero-identity machines still get s_capacity=100 (NULL-ignoring LEAST/GREATEST) - changing
it would have dropped the stale VOX P1s (T3 guard).

## T-tests (dry-proofed in rolled-back txn, re-verified live post-apply)

| Test                | Result                                                                                                                                                                                                         |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1 AMZ-1038         | PASS - P1_RESTOCK, urg 56.58, empty_ab=2, reasons [hero_runout, hero_shelf_empty, seller_below_horizon, empty_shelves, high_urgency]. Empty slots both grade A: Hunter Ridge (0/8), Dubai Popcorn (0/6).       |
| T2 MC-2004          | PASS - s_empty 1.50 (+reason empty_shelves), urg 15.74, stays P3_OK: its single empty shelf (Coco Max - Regular) grades **C**, so no tier move - exactly per design.                                           |
| T3 regression       | PASS - all 9 baseline P1 machines still P1 (dropped: NONE).                                                                                                                                                    |
| T4 distribution     | PASS - main P1 2->3, P2 1->0, P3 19; vox P1 7, P3 1. Total P1 9 -> 10 (ceiling 18). No flood; no w_empty tuning needed. The mover: NOOK-1019-0200-B1 (baseline P2) -> P1 via hero_shelf_empty + empty_shelves. |
| T5 track separation | PASS - main 22 / vox 8, svc_track logic untouched.                                                                                                                                                             |

## Current P1 list (live, post-apply)

| Track | Machine                                                | Urgency | Reasons                                                                                         |
| ----- | ------------------------------------------------------ | ------- | ----------------------------------------------------------------------------------------------- |
| main  | AMZ-1038-3001-O1                                       | 56.58   | hero_runout, hero_shelf_empty, seller_below_horizon, empty_shelves, high_urgency                |
| main  | NOOK-1019-0200-B1                                      | 30.87   | hero_shelf_empty, seller_below_horizon, empty_shelves                                           |
| main  | AMZ-1029-3003-O1                                       | 22.11   | hero_runout, seller_below_horizon                                                               |
| vox   | VOXMCC-1005-0201-B0                                    | 71.31   | hero_runout, stale_overdue, hero_shelf_empty, seller_below_horizon, empty_shelves, high_urgency |
| vox   | VOXMCC-1011-0101-B0                                    | 45.82   | stale_overdue, hero_shelf_empty, seller_below_horizon, empty_shelves                            |
| vox   | ACTIVATE-2005 / IFLYMCC-1024 / MPMCC-1054 / MPMCC-1058 | 30.00   | stale_overdue, low_capacity                                                                     |
| vox   | ACTIVATEMCC-1037                                       | 20.54   | stale_overdue                                                                                   |

## Skips / follow-ups

1. **repurposed-but-Active x3** (WS-A finding): CS decision on ACTIVATE-2005 /
   IFLYMCC-1024 / MPMCC-1054 repurposed_at - until then they stay grading-blind and
   P1-by-staleness only; the drift monitor keeps them visible.
2. Admin MachineEditPanel still edits the column as free text - DB constraint now rejects
   invalid values with a clear error; optional UX follow-up to make it a select.
3. Registry versions realigned by UPDATE to committed filenames (20260704130000/140000).
