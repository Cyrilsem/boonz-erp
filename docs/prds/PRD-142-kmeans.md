# PRD-142a: K-means diagnostic and archetype rules

Generated 2026-10-18 by `scripts/strategy/kmeans_diagnostic.py` (standard library only; plpython3u is not installed and numpy is not available locally) over `machine_features` as_of 2026-10-17. K-means++ seeding, 200 restarts per k, best inertia kept, features standardised to z-scores, NULLs imputed with the population median. Machines under 90 days are excluded. This is a diagnostic: the rules it informed are locked in `machine_archetypes` and are what the nightly job evaluates.

## Decision

- Boonz: k = 4 has the best silhouette (0.230; k=3 0.160, k=5 0.220, k=6 0.158). The four clusters are: an AMZ engine pair (170 AED/day, 29 units/day, lunch share 0.47), a 13-machine core office group (50 AED/day, dead shelves 7%), a 6-machine low-volume group (13 AED/day, dead shelves 51%) and GRIT alone (gym, drinks-led, evening peaks). Silhouettes are low in absolute terms (22 machines, 11 features): the clusters are a guide, not a hard partition.
- Partner: k = 3 is best (0.186; k=2 0.151, k=4 0.185): LVLUP (ticket about 10, weekend 0.26, snack-led), and two cinema/leisure groups (ticket about 22, weekend 0.42 to 0.46, drinks-led) that split mainly on volume.

## Rules locked in machine_archetypes (sort order, first match wins)

| Order | Code | Population | Rule | Why (from the centroids) |
| --- | --- | --- | --- | --- |
| 10 | RAMPING | all | age_days < 90 | spec; benchmarked on the ramp curve |
| 20 | SEASONAL_SWINGER (override) | boonz | cv_monthly_12 >= 0.60 | spec said 0.45; at 0.45 it claimed 9 of 22 mature machines, and CV is not a separating feature in any k (cluster CVs 0.26 to 0.57), so most of that variance is growth, not seasonality. 0.60 keeps the 5 most volatile. Base archetype kept in features.base_archetype |
| 30 | GYM_GRAB | boonz | peak share >= 0.45, at least 2 of the top 3 hours outside 11:00 to 15:59, drinks share >= 0.5 | spec; GRIT cluster |
| 40 | OFFICE_LUNCH_ENGINE | boonz | weekday lunch share >= 0.35, units/day >= population median | spec; core and engine clusters |
| 50 | PREMIUM_OFFICE | boonz | lunch share >= 0.25, ticket >= population p70, units/day < median | spec |
| 60 | LOBBY_TRICKLE | boonz | units/day < population p40 | spec also required peak share < 0.30; no Boonz machine is under 0.396 (the low cluster's peak share is 0.52, higher than the core), so that condition was dropped |
| 70 | OFFICE_STANDARD | boonz | fallback | new: mid-volume offices no rule claims (confidence 0.6) |
| 40 | CINEMA_IMPULSE | partner | weekend share >= 0.30 and ticket >= AED 15 | spec said weekend >= 0.40, which misses real cinemas (VOXMCC-1012 0.346, VOXMCC-1005 0.389); the k=3 split is ticket and drinks, not weekend alone |
| 70 | VENUE_STANDARD | partner | fallback | spec; the LVLUP cluster |

Percentiles are computed nightly per population over machines aged 90 days or more. drinks_share counts attr_drink or a drinks pod category: Al Ain Zero's attr_drink read false on 2026-10-18, which briefly sent GRIT to LOBBY_TRICKLE.

## Assignment on 2026-10-17 (42 machines)

| Archetype | Machines |
| --- | --- |
| OFFICE_LUNCH_ENGINE (8) | ADDMIND-1007, AMZ-1029, AMZ-1038, AMZ-1057, AMZ-1068, HUAWEI-2003, OMDCW-1021, VML-1003 |
| PREMIUM_OFFICE (3) | NISSAN-0804, NOOK-1019, NOVO-1023 |
| LOBBY_TRICKLE (4) | ALJLT-1015-0100, ALJLT-1015-0200, VML-1004, WAVEMAKER-1006 |
| OFFICE_STANDARD (1) | OMDBB-1020 |
| GYM_GRAB (1) | GRIT-1022 |
| SEASONAL_SWINGER (5) | JET-1016 (base LOBBY_TRICKLE), MC-2004 (base OFFICE_LUNCH_ENGINE), MINDSHARE-1009 (base LOBBY_TRICKLE), USH-1008 (base OFFICE_STANDARD), WPP-1002 (base PREMIUM_OFFICE) |
| RAMPING (7) | AMZ-1046, BEBEACH-1069, IRIS-1070, SAP-2002; partner ACTIVATEMOE-2007, VOXDFC-1001, VOXDFC-2006 |
| CINEMA_IMPULSE (10) | ACTIVATEMCC-1037, ACTIVATEMCC-2005, IFLYMCC-1024, MPMCC-1054, MPMCC-1058, VOXMCC-1005, VOXMCC-1011, VOXMCC-1012, VOXMCC-1017, VOXMM-1013 |
| VENUE_STANDARD (3) | LVLUP-1018, LVLUP-1048, LVLUP-2015 |

## Raw output: Boonz

Machines clustered: 22. Excluded (age under 90 days): AMZ-1046-2406-O1, BEBEACH-1069-0000-W0, IRIS-1070-0000-O1, SAP-2002-0000-R1.

Features standardised to z-scores; NULLs imputed with the population median:
| feature | median | mean | sd | imputed |
| --- | --- | --- | --- | --- |
| rev_day_90 | 38.015 | 48.773 | 44.431 | 0 |
| units_day_90 | 5.120 | 7.053 | 7.524 | 0 |
| ticket_90 | 9.495 | 9.501 | 2.421 | 0 |
| card_share_90 | 1.000 | 0.953 | 0.208 | 0 |
| peak_hour_share_90 | 0.465 | 0.480 | 0.056 | 0 |
| weekend_share_90 | 0.019 | 0.035 | 0.046 | 0 |
| weekday_lunch_share_90 | 0.458 | 0.436 | 0.104 | 0 |
| drinks_share_90 | 0.353 | 0.368 | 0.185 | 0 |
| top5_shelf_share_90 | 0.622 | 0.604 | 0.078 | 0 |
| dead_shelf_pct_90 | 0.094 | 0.203 | 0.241 | 0 |
| cv_monthly_12 | 0.383 | 0.438 | 0.186 | 0 |

## Silhouette per k

| k | silhouette | inertia |
| --- | --- | --- |
| 3 | 0.160 | 150.80 |
| 4 | 0.230 | 117.96 |
| 5 | 0.220 | 95.60 |
| 6 | 0.158 | 80.77 |

## k = 3 (silhouette 0.160)

Centroids in raw units (mean of members):

| cluster | n | rev_day_90 | units_day_90 | ticket_90 | card_share_90 | peak_hour_share_90 | weekend_share_90 | weekday_lunch_share_90 | drinks_share_90 | top5_shelf_share_90 | dead_shelf_pct_90 | cv_monthly_12 | machines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 1 | 4.51 | 1.42 | 3.50 | 1.00 | 0.60 | 0.20 | 0.16 | 1.00 | 0.68 | 0.56 | 0.57 | GRIT-1022-0100-W0 |
| 1 | 8 | 17.82 | 2.36 | 9.89 | 0.88 | 0.52 | 0.02 | 0.46 | 0.29 | 0.65 | 0.41 | 0.52 | ADDMIND-1007-0000-W0, ALJLT-1015-0100-B1, JET-1016-0000-O1, MINDSHARE-1009-4500-O1, NOVO-1023-0000-W0, VML-1004-0500-O1, WAVEMAKER-1006-4100-O1, WPP-1002-4300-O1 |
| 2 | 13 | 71.22 | 10.37 | 9.72 | 1.00 | 0.45 | 0.03 | 0.44 | 0.36 | 0.57 | 0.05 | 0.38 | ALJLT-1015-0200-O1, AMZ-1029-3003-O1, AMZ-1038-3001-O1, AMZ-1057-2403-O1, AMZ-1068-2401-O1, HUAWEI-2003-0000-B1, MC-2004-0100-O1, NISSAN-0804-0000-L0, NOOK-1019-0200-B1, OMDBB-1020-0P00-O1, OMDCW-1021-0100-W0, USH-1008-0000-W1, VML-1003-0400-O1 |

## k = 4 (silhouette 0.230)

Centroids in raw units (mean of members):

| cluster | n | rev_day_90 | units_day_90 | ticket_90 | card_share_90 | peak_hour_share_90 | weekend_share_90 | weekday_lunch_share_90 | drinks_share_90 | top5_shelf_share_90 | dead_shelf_pct_90 | cv_monthly_12 | machines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 1 | 4.51 | 1.42 | 3.50 | 1.00 | 0.60 | 0.20 | 0.16 | 1.00 | 0.68 | 0.56 | 0.57 | GRIT-1022-0100-W0 |
| 1 | 13 | 50.07 | 6.55 | 10.29 | 1.00 | 0.46 | 0.03 | 0.44 | 0.35 | 0.57 | 0.07 | 0.45 | ADDMIND-1007-0000-W0, ALJLT-1015-0200-O1, AMZ-1057-2403-O1, AMZ-1068-2401-O1, HUAWEI-2003-0000-B1, MC-2004-0100-O1, NISSAN-0804-0000-L0, NOOK-1019-0200-B1, OMDBB-1020-0P00-O1, OMDCW-1021-0100-W0, USH-1008-0000-W1, VML-1003-0400-O1, WPP-1002-4300-O1 |
| 2 | 2 | 170.11 | 28.77 | 7.66 | 1.00 | 0.44 | 0.01 | 0.47 | 0.44 | 0.60 | 0.00 | 0.26 | AMZ-1029-3003-O1, AMZ-1038-3001-O1 |
| 3 | 6 | 12.90 | 1.84 | 9.41 | 0.83 | 0.52 | 0.02 | 0.46 | 0.28 | 0.67 | 0.51 | 0.45 | ALJLT-1015-0100-B1, JET-1016-0000-O1, MINDSHARE-1009-4500-O1, NOVO-1023-0000-W0, VML-1004-0500-O1, WAVEMAKER-1006-4100-O1 |

## k = 5 (silhouette 0.220)

Centroids in raw units (mean of members):

| cluster | n | rev_day_90 | units_day_90 | ticket_90 | card_share_90 | peak_hour_share_90 | weekend_share_90 | weekday_lunch_share_90 | drinks_share_90 | top5_shelf_share_90 | dead_shelf_pct_90 | cv_monthly_12 | machines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 2 | 170.11 | 28.77 | 7.66 | 1.00 | 0.44 | 0.01 | 0.47 | 0.44 | 0.60 | 0.00 | 0.26 | AMZ-1029-3003-O1, AMZ-1038-3001-O1 |
| 1 | 1 | 14.39 | 1.96 | 9.32 | 0.00 | 0.52 | 0.01 | 0.47 | 0.25 | 0.70 | 0.44 | 0.72 | JET-1016-0000-O1 |
| 2 | 1 | 4.51 | 1.42 | 3.50 | 1.00 | 0.60 | 0.20 | 0.16 | 1.00 | 0.68 | 0.56 | 0.57 | GRIT-1022-0100-W0 |
| 3 | 5 | 12.61 | 1.82 | 9.43 | 1.00 | 0.52 | 0.02 | 0.46 | 0.29 | 0.66 | 0.53 | 0.39 | ALJLT-1015-0100-B1, MINDSHARE-1009-4500-O1, NOVO-1023-0000-W0, VML-1004-0500-O1, WAVEMAKER-1006-4100-O1 |
| 4 | 13 | 50.07 | 6.55 | 10.29 | 1.00 | 0.46 | 0.03 | 0.44 | 0.35 | 0.57 | 0.07 | 0.45 | ADDMIND-1007-0000-W0, ALJLT-1015-0200-O1, AMZ-1057-2403-O1, AMZ-1068-2401-O1, HUAWEI-2003-0000-B1, MC-2004-0100-O1, NISSAN-0804-0000-L0, NOOK-1019-0200-B1, OMDBB-1020-0P00-O1, OMDCW-1021-0100-W0, USH-1008-0000-W1, VML-1003-0400-O1, WPP-1002-4300-O1 |

## k = 6 (silhouette 0.158)

Centroids in raw units (mean of members):

| cluster | n | rev_day_90 | units_day_90 | ticket_90 | card_share_90 | peak_hour_share_90 | weekend_share_90 | weekday_lunch_share_90 | drinks_share_90 | top5_shelf_share_90 | dead_shelf_pct_90 | cv_monthly_12 | machines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 7 | 49.38 | 5.80 | 11.61 | 1.00 | 0.46 | 0.04 | 0.39 | 0.28 | 0.60 | 0.05 | 0.51 | ADDMIND-1007-0000-W0, NISSAN-0804-0000-L0, NOOK-1019-0200-B1, OMDBB-1020-0P00-O1, OMDCW-1021-0100-W0, USH-1008-0000-W1, WPP-1002-4300-O1 |
| 1 | 6 | 50.86 | 7.43 | 8.75 | 1.00 | 0.45 | 0.02 | 0.50 | 0.43 | 0.54 | 0.08 | 0.38 | ALJLT-1015-0200-O1, AMZ-1057-2403-O1, AMZ-1068-2401-O1, HUAWEI-2003-0000-B1, MC-2004-0100-O1, VML-1003-0400-O1 |
| 2 | 5 | 12.61 | 1.82 | 9.43 | 1.00 | 0.52 | 0.02 | 0.46 | 0.29 | 0.66 | 0.53 | 0.39 | ALJLT-1015-0100-B1, MINDSHARE-1009-4500-O1, NOVO-1023-0000-W0, VML-1004-0500-O1, WAVEMAKER-1006-4100-O1 |
| 3 | 2 | 170.11 | 28.77 | 7.66 | 1.00 | 0.44 | 0.01 | 0.47 | 0.44 | 0.60 | 0.00 | 0.26 | AMZ-1029-3003-O1, AMZ-1038-3001-O1 |
| 4 | 1 | 4.51 | 1.42 | 3.50 | 1.00 | 0.60 | 0.20 | 0.16 | 1.00 | 0.68 | 0.56 | 0.57 | GRIT-1022-0100-W0 |
| 5 | 1 | 14.39 | 1.96 | 9.32 | 0.00 | 0.52 | 0.01 | 0.47 | 0.25 | 0.70 | 0.44 | 0.72 | JET-1016-0000-O1 |


## Raw output: partner

Machines clustered: 13. Excluded (age under 90 days): ACTIVATEMOE-2007-0000-B0, VOXDFC-1001-0100-V0, VOXDFC-2006-0200-B0.

Features standardised to z-scores; NULLs imputed with the population median:
| feature | median | mean | sd | imputed |
| --- | --- | --- | --- | --- |
| rev_day_90 | 104.010 | 123.403 | 73.422 | 0 |
| units_day_90 | 8.220 | 11.366 | 8.109 | 0 |
| ticket_90 | 17.200 | 19.045 | 6.424 | 0 |
| card_share_90 | 0.992 | 0.990 | 0.009 | 1 |
| peak_hour_share_90 | 0.363 | 0.362 | 0.049 | 0 |
| weekend_share_90 | 0.405 | 0.396 | 0.091 | 0 |
| weekday_lunch_share_90 | 0.049 | 0.064 | 0.030 | 0 |
| drinks_share_90 | 0.732 | 0.642 | 0.271 | 2 |
| top5_shelf_share_90 | 0.641 | 0.645 | 0.092 | 0 |
| dead_shelf_pct_90 | 0.077 | 0.094 | 0.067 | 0 |
| cv_monthly_12 | 0.281 | 0.296 | 0.083 | 3 |

## Silhouette per k

| k | silhouette | inertia |
| --- | --- | --- |
| 2 | 0.151 | 109.11 |
| 3 | 0.186 | 82.54 |
| 4 | 0.185 | 63.34 |

## k = 2 (silhouette 0.151)

Centroids in raw units (mean of members):

| cluster | n | rev_day_90 | units_day_90 | ticket_90 | card_share_90 | peak_hour_share_90 | weekend_share_90 | weekday_lunch_share_90 | drinks_share_90 | top5_shelf_share_90 | dead_shelf_pct_90 | cv_monthly_12 | machines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 8 | 91.70 | 9.93 | 17.12 | 1.00 | 0.38 | 0.38 | 0.08 | 0.56 | 0.64 | 0.12 | 0.26 | ACTIVATEMCC-1037-0000-L0, ACTIVATEMCC-2005-0000-W0, IFLYMCC-1024-0000-W0, LVLUP-1018-0000-G0, LVLUP-1048-0000-P0, LVLUP-2015-0000-R0, MPMCC-1054-0000-M0, MPMCC-1058-0000-R0 |
| 1 | 5 | 174.13 | 13.67 | 22.13 | 0.98 | 0.33 | 0.42 | 0.04 | 0.78 | 0.66 | 0.06 | 0.35 | VOXMCC-1005-0201-B0, VOXMCC-1011-0101-B0, VOXMCC-1012-0100-V0, VOXMCC-1017-0200-V0, VOXMM-1013-0101-B0 |

## k = 3 (silhouette 0.186)

Centroids in raw units (mean of members):

| cluster | n | rev_day_90 | units_day_90 | ticket_90 | card_share_90 | peak_hour_share_90 | weekend_share_90 | weekday_lunch_share_90 | drinks_share_90 | top5_shelf_share_90 | dead_shelf_pct_90 | cv_monthly_12 | machines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 4 | 93.33 | 9.27 | 22.25 | 1.00 | 0.38 | 0.46 | 0.08 | 0.75 | 0.57 | 0.16 | 0.23 | ACTIVATEMCC-2005-0000-W0, IFLYMCC-1024-0000-W0, MPMCC-1054-0000-M0, MPMCC-1058-0000-R0 |
| 1 | 3 | 81.55 | 10.17 | 10.25 | 0.99 | 0.38 | 0.26 | 0.07 | 0.17 | 0.66 | 0.08 | 0.28 | LVLUP-1018-0000-G0, LVLUP-1048-0000-P0, LVLUP-2015-0000-R0 |
| 2 | 6 | 164.38 | 13.36 | 21.31 | 0.98 | 0.34 | 0.42 | 0.05 | 0.80 | 0.69 | 0.06 | 0.35 | ACTIVATEMCC-1037-0000-L0, VOXMCC-1005-0201-B0, VOXMCC-1011-0101-B0, VOXMCC-1012-0100-V0, VOXMCC-1017-0200-V0, VOXMM-1013-0101-B0 |

## k = 4 (silhouette 0.185)

Centroids in raw units (mean of members):

| cluster | n | rev_day_90 | units_day_90 | ticket_90 | card_share_90 | peak_hour_share_90 | weekend_share_90 | weekday_lunch_share_90 | drinks_share_90 | top5_shelf_share_90 | dead_shelf_pct_90 | cv_monthly_12 | machines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 3 | 81.55 | 10.17 | 10.25 | 0.99 | 0.38 | 0.26 | 0.07 | 0.17 | 0.66 | 0.08 | 0.28 | LVLUP-1018-0000-G0, LVLUP-1048-0000-P0, LVLUP-2015-0000-R0 |
| 1 | 3 | 232.07 | 24.02 | 17.47 | 0.99 | 0.32 | 0.43 | 0.06 | 0.85 | 0.62 | 0.04 | 0.25 | ACTIVATEMCC-2005-0000-W0, VOXMCC-1005-0201-B0, VOXMCC-1011-0101-B0 |
| 2 | 3 | 120.13 | 6.26 | 24.72 | 0.98 | 0.34 | 0.43 | 0.03 | 0.76 | 0.64 | 0.09 | 0.41 | VOXMCC-1012-0100-V0, VOXMCC-1017-0200-V0, VOXMM-1013-0101-B0 |
| 3 | 4 | 75.74 | 6.61 | 22.57 | 1.00 | 0.39 | 0.45 | 0.09 | 0.76 | 0.66 | 0.14 | 0.26 | ACTIVATEMCC-1037-0000-L0, IFLYMCC-1024-0000-W0, MPMCC-1054-0000-M0, MPMCC-1058-0000-R0 |

