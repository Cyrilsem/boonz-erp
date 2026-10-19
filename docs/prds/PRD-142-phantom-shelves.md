# PRD-142 phantom shelves (cleanup list for a later night window)

Written by PRD-142b A8 on 2026-10-19 (Dubai). Source: shelf_configurations rows whose cabinet index (A = 0, B = 1, ...) is at or above machines.cabinet_count. Nothing below was deleted or edited: planner views and the slot guard read shelf_configurations, so the cleanup needs its own night-window change with a full-fleet draft-plan diff, after CS approves this list.

Since A8 the strategy page (get_strategy_machine_detail shelf grid, build_machine_features shelf KPIs) ignores these cabinets through `strategy_cabinet_in_scope()`.

## Rows not yet flagged is_phantom (the real cleanup: 152 rows on 6 refill machines)

| Machine | cabinet_count | Phantom cabinets | Rows |
| --- | --- | --- | --- |
| AMZ-1029-3003-O1 | 1 | B (16), C (3), D (3), E (2) | 24 |
| AMZ-1038-3001-O1 | 1 | B (16), C (3), D (3), E (2) | 24 |
| AMZ-1057-2403-O1 | 1 | B (16), C (3), D (3), E (2) | 24 |
| AMZ-1068-2401-O1 | 1 | B (16), C (3), D (3), E (2) | 24 |
| AMZ-1046-2406-O1 | 1 | B (16) | 16 |
| BEBEACH-1069-0000-W0 | 1 | B (16) | 16 |

## Phantom cabinets already flagged is_phantom = true (B, 16 rows each; engine already skips them)

In refill: ACTIVATEMCC-1037, ADDMIND-1007, ALJLT-1015-0100, GRIT-1022, IFLYMCC-1024, IRIS-1070, MINDSHARE-1009, MPMCC-1054, MPMCC-1058, NISSAN-0804, NOOK-1019, NOVO-1023, OMDBB-1020, OMDCW-1021, USH-1008, VML-1003, VML-1004, VOXMCC-1005, VOXMCC-1011, VOXMM-1013, WAVEMAKER-1006, WPP-1002.
Not in refill: ALHQ-1016, ALJ-1014-0200-O1_OLD, LVLUP-1018, VOXDFC-1001, VOXMCC-1012, VOXMCC-1017.

## Other notes

- VOXMCC-1012, VOXMCC-1017, VOXDFC-1001 (VOX_PREMIUM_13 layout) also carry A14 to A16 rows flagged is_phantom (3 each); they are inside cabinet A so the cabinet rule keeps them, the is_phantom flag already hides them.
- SAP-2002 (cabinet_count 2) has 2 is_phantom rows in A and 2 in B; not cabinet phantoms.
- No cabinet_count: LVLUP-1048 and LVLUP-2015 (both outside refill); the A8 fallback keeps A and B for both because both cabinets had a sale or a pod_inventory snapshot in the last 180 days.
- Check before cleanup: on all machines above, no lane beyond cabinet_count has a current product or a sale in 180 days (query in the PRD-142b log, A8).

## Proposed cleanup (not applied)

Set is_phantom = true on the 152 unflagged rows (not DELETE), in the night window, with a rolled-back full-fleet draft-plan diff before and after, after checking that v_live_shelf_stock, v_shelf_capacity and the slot guard return no row for them.
