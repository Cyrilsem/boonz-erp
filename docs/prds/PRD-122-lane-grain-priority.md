# PRD-122: Lane-Grain Priority (Emptiness, Capacity, Service Track)

**Status:** Approved to build. Rev 2, 2026-09-14. Q1 to Q3 and Q6 to Q10 resolved 2026-09-13. Q4, Q5 and Q11 resolved 2026-09-14 from Claude Code's step-1 read-only verification, confirmed independently. Section 7 carries measured, not projected, numbers. **T7 is cut from this PRD, see Q4.**
**Supabase:** eizcexopcuoycuosittm. **Repo:** boonz-erp, main. **Author:** CS work order.
**Scope discipline:** surgical only. Nothing outside T1 to T7.

---

## 1. Problem

`v_machine_priority` scores refill urgency at the wrong grain, scores it with a function that discards signal, and gates a whole service track on the wrong column.

**1a. Emptiness is diluted by facing count.** `v_shelf_sales_identity` groups by `(machine_id, pod_product_id)`, not by physical lane. A multi-facing product collapses into one row with `stock = sum(current_stock)` across every facing. `v_machine_priority`'s `shelf_graded` CTE reads `is_empty := (i.stock = 0)` off that row, so a 3-facing product only counts as empty when all 3 facings are simultaneously at zero.

Worked example, ACTIVATEMCC-1037-0000-L0 on 2026-09-13: lane A10 holds Aquafina at 0 of 17, a genuinely empty hero lane. Aquafina occupies A09 (3 of 17), A10 (0 of 17) and A11 (5 of 17). It rolls up to one row: 3 facings, 8 units, cap 51. `is_empty` is false. `s_empty` is 0.00.

Fleet-wide effect: `s_empty = 0.00` on 31 of 32 in-scope machines, while `w_empty = 0.945` is the single heaviest weight in `pick_urgency_params`. The heaviest-weighted signal in the model produces almost no output. `s_lowfill` inherits the same dilution, and `graded_shelves`, the denominator for both, is a product count (9 for ACTIVATEMCC-1037) not a lane count (16).

**1b. `p_score` is a MAX, so signals never accumulate, and capacity is discarded.** `p_score = GREATEST(s_runout, s_empty, s_lowfill, s_expiry, s_stale, s_holes)`. A machine moderately bad on five axes scores no worse than one bad on a single axis. `s_capacity` (`1 - abc_stock/abc_cap`) is computed and then used nowhere: its only live effect is a cosmetic `'low_capacity'` reason tag at `s_capacity >= 50`, with zero weight in the score or the tier test.

Measured: VML-1003-0400-O1 at 45.78% fill with `s_capacity = 54.22` sits at `P3_OK` (4.67), while JET-1016-0000-O1 at 71.51% fill leads the entire fleet at `P1_RESTOCK` (92.86) on staleness alone.

**1c. The VOX service track is gated on the landlord, not the filler.** `svc_track = CASE WHEN venue_group = 'VOX' THEN 'vox' ELSE 'main' END`. `venue_group` records who owns the venue (MAF at Mirdif City Centre), not who physically refills the machine. The 3 machines VOX staff actually fill are the `-V0` suffix units (VOXMM-1001-0100-V0, VOXMCC-1012-0100-V0, VOXMCC-1017-0200-V0) and all 3 already carry `include_in_refill = false`, so they never reach the picker regardless of track.

The gate's only live effect is demoting 8 Boonz-filled machines out of the main P1 list and out of the every-day eligibility window: ACTIVATEMCC-1037, ACTIVATE-2005, IFLYMCC-1024, MPMCC-1054, MPMCC-1058, VOXMCC-1005, VOXMCC-1011, VOXMM-1013.

Three surfaces compound it. `SnapshotTab.tsx` sorts `service_track='vox'` below a dashed separator and its "P1 restock" legend pill counts `service_track !== 'vox'` only, so a vox-track P1 is invisible as a P1. `pick_machines_for_refill` on a non-VOX day only admits a `venue_group='VOX'` P1 when `runway_days < days_until_next_vox_day`; ACTIVATEMCC-1037 at 10.7 days machine runway against 3 days to Wednesday is not picked, despite its Aquafina hero sitting at 0.93 days of supply. And excluded machines sort to the very end of the grid, which places LVLUP and LLFP visually under the VOX header, making them look partner-serviced.

## 2. Verified facts

Confirmed live 2026-09-13 via `pg_get_viewdef`, `pg_get_functiondef` and `information_schema`.

- **F1.** `v_shelf_sales_identity` is product grain. Its `shelf` CTE groups `v_live_shelf_stock` by `(machine_id, COALESCE(alias.canonical_pod, pod_product_id))` under `is_enabled AND NOT is_broken AND is_eligible_machine AND pod_product_id IS NOT NULL`. Emits `facings = count(*)`, `stock = sum(current_stock)`, `cap = sum(max_stock)`, `dvel = units_30d / 30.0`, and `dos = stock / (units_30d/30.0)` when `units_30d > 0` else NULL.
- **F2.** `v_live_shelf_stock` is lane grain, one row per physical facing, carrying `machine_id, slot_name, pod_product_id, current_stock, max_stock, is_broken, is_enabled, is_eligible_machine`. This is the correct source for T1.
- **F3.** `v_machine_priority_base` is a CTE inside `v_machine_priority`'s own WITH clause, not a separate view, table or matview (confirmed via `pg_class`, 2026-09-14). Grading (`shelf_graded`), aggregation (`magg`, `hole_agg`) and scoring (`mscore`) all live in that CTE, cross-joined once against `pick_urgency_params` and once against `v_shelf_sales_identity`. That second join is what T1 and T2 replace. **Consequence for T2 to T4: the rebuild is one `CREATE OR REPLACE VIEW v_machine_priority` editing the nested CTE, not edits to two independent objects.**
- **F4.** `p_score` and `urgency` are two output columns carrying the identical `GREATEST(...)` expression. `get_machine_health`'s `urgency_breakdown` computes each weighted chip and attributes the remainder of `urgency` to a `'runout'` chip, which is meaningless because `urgency` is a MAX, not a sum of the subtracted terms. Resolved Q1: `urgency` keeps the old `GREATEST(...)` as a rollback comparison column; only `p_score` becomes the blend.
- **F5.** `pick_urgency_params` (single row, `id = 1`), values relevant here: `a_floor=0.5, b_floor=0.2, grade_wt_a=1.0, grade_wt_b=0.6, grade_wt_c=0.25, hole_frac=0.15, holes_norm=3, hole_wt_a=1.0/b=0.8/c=0.6/d=0.4, empty_wt_a=1.0/b=0.7/c=0.45/d=0.25, w_empty=0.945, w_lowfill=0.5, w_runout=0.35, w_capacity=0.10, w_expiry=0.12, w_stale=0.13, w_holes=0.30, w_intents=0, p1_threshold=50, p2_threshold=25, p1_holes_min=2, p2_holes_min=1, p1_empty_ab_min=1, p1_expired_min=1, horizon_days=2, runout_worst_wt=0.75, runout_breadth_wt=0.25, stale_override_days=14, cooldown_days=1`.
- **F6.** `pick_machines_for_refill` (v11) has exactly 6 `venue_group` predicates plus one reason-tag CASE.
  - Eligibility, moving to `svc_track`: the `v_vox_all_equip` bool_and check; `vox_sel`; `nonvox_sel`; the VOX-off-day gate inside `ranked_primary`'s WHERE (also T4's swap-in point); `sibling_ranked`'s `IS DISTINCT FROM 'VOX'`.
  - Routing, staying on `venue_group`: `vox_centroid`'s geography clustering.
  - Resolved Q3: the `'vox_emergency_offday'` reason tag in the `ordered` CTE also moves to `svc_track`, since it fires exactly when a machine crosses the gate being re-keyed.
  - The final `ORDER BY (fp.svc_track = 'vox')` already reads `svc_track`. No change.
- **F7.** `get_machine_health`'s fallback is `COALESCE(mp.svc_track, CASE WHEN we.venue_grp = 'VOX' THEN 'vox' ELSE 'main' END)`.
- **F8.** `get_machine_slots_with_expiry`'s `suggested_product` comes from `latest_ri.suggested_product`, the most-recent-`report_timestamp` batch from `refill_instructions`, LEFT JOINed per lane on `normalize_slot(ri.slot_name) = normalize_slot(ai.slot)`. All 16 lanes of ACTIVATEMCC-1037 return NULL. **Root cause found 2026-09-14 and it is not a join defect: `refill_instructions` is an abandoned table.** 1251 rows total, 466 carrying `suggested_product`, all of those between 2026-01-19 and 2026-03-31. The last write of any kind was 2026-06-08. Its only writer is `upsert_refill_stock_snapshot`, whose INSERT column list has never included `suggested_product` at all, and no cron job calls it. There is no join to reconnect. See Q4.
- **F9.** `machines` has no `service_model` column. T5's ALTER is additive, not a rename.
- **F11.** `check_priority_surface_consistency()` is a drift detector comparing `get_machine_health`'s outputs against `v_machine_priority`, over 11 fields. It **returns 0 rows today**, fleet-wide: every check currently passes. It independently re-derives the chip formulas, including F4's leftover-equals-runout subtraction, and it is the third reader of `w_capacity` and `w_intents`. It is not named in T1 to T7. See Q11 and R3b.
- **F10.** Lane grading on `lane_dvel = dvel / facings` systematically demotes multi-facing products relative to today's product-level grading. On ACTIVATEMCC-1037: Aquafina (dvel 8.57 over 3 facings, lane_dvel 2.86) stays A; Vitamin Well (0.80 over 4 facings, 0.20) lands exactly on `b_floor` and becomes B; Evian 1L (0.533 over 2 facings, 0.267) drops A to B. Fleet-wide this leaves **9 of 32 machines with zero A-grade lanes**: WPP-1002, GRIT-1022, WAVEMAKER-1006, MINDSHARE-1009, JET-1016, ALJLT-1015-0100, NOVO-1023, IRIS-1070, IFLYMCC-1024. This is intended behaviour (per lane, those really are B lanes) but it is load-bearing for T4, see R4 and Q7.

## 3. Requirements

- **R1 (T1).** New view `public.v_lane_grain`, lane grain, from `v_live_shelf_stock` under F1's eligibility filter, joined to `v_shelf_sales_identity` for `dvel`, `facings` and `dos` at `(machine_id, pod_product_id)`. Per lane: `lane_dvel = dvel / facings`; `grade` by existing `a_floor`/`b_floor` on `lane_dvel`; `w` from `grade_wt_a/b/c` plus new `lane_wt_d` (0.05); `fill_ratio = current_stock / NULLIF(max_stock,0)`; `is_empty = (current_stock = 0)`; `is_quasi = (fill_ratio > 0 AND fill_ratio <= quasi_fill_floor)`. New `pick_urgency_params` columns: `quasi_fill_floor numeric DEFAULT 0.25`, `lane_wt_d numeric DEFAULT 0.05`, `w_gap numeric DEFAULT 0.30`, `p1_gap_min numeric DEFAULT 40`. Raise `hole_frac` 0.15 to 0.25.
- **R2 (T2).** Rebuild `s_empty` and `s_lowfill` on `v_lane_grain` at lane grain. Add `s_gap = 100 * sum(w * (1 - COALESCE(fill_ratio,0))) / sum(w)`. Add exposed columns `pct_empty_lanes`, `pct_quasi_lanes`, `pct_ab_empty_or_quasi`. Rebuild `empty_ab_count` from lane grain (any A or B lane at `current_stock = 0`), `p1_empty_ab_min` stays 1. Every existing column name and type in `v_machine_priority` survives. `s_expiry` and `s_stale` formulas untouched.
- **R3 (T3).** `p_score` becomes a weighted sum reading its weights from `pick_urgency_params`:

  `p_score = round(w_runout * s_runout_hero + w_gap * s_gap + w_holes * s_holes + w_expiry * s_expiry + w_stale * s_stale, 2)`

  with `w_holes` updated 0.30 to 0.15 and `w_stale` 0.13 to 0.08 in the same migration (Q2), so the five weights sum to 1.00 and every reader moves off one column each. `urgency` keeps the old `GREATEST(...)` untouched (Q1). Every existing hard-override P1 rule stays exactly as-is, including `stale_override_days` (Q10). New override: P1 when `s_gap >= p1_gap_min` (40). New reasons: `'capacity_gap'` at `s_gap >= p1_gap_min`, `'quasi_empty_heavy'` at `pct_ab_empty_or_quasi >= 25`. Re-tune `p1_threshold` 50 to 32 and `p2_threshold` 25 to 18. Print the full 32-machine before and after tier table in the PR body. **There is no hard stop on the P1 count** (Q8): CS has accepted that P1 becomes a ranked queue rather than a shortlist.

- **R4 (T4).** New `s_runout_hero` and `hero_runway_days` in `v_machine_priority`. `hero_runway_days` is the soonest-emptying lane of the **highest grade present that has a non-null `dos`**, walking A then B then C (Q7). If no graded lane has a `dos`, `hero_runway_days` is NULL and `s_runout_hero` is 0, never NULL. `horizon_days` 2 to 4. `runout_breadth_wt`'s input changes from a mean over every graded A/B/C lane to a mean over the **worst three** by `shelf_runout`. `pick_machines_for_refill`'s VOX-off-day gate tests `hero_runway_days`, not `runway_days`.
- **R5 (T5).** `machines.service_model text NOT NULL DEFAULT 'boonz_filled' CHECK (service_model IN ('boonz_filled','partner_filled'))`, backfilled `'partner_filled'` for exactly the 3 `-V0` machines in F1c, everything else `'boonz_filled'`. `svc_track` keys on `m.service_model`. `get_machine_health`'s fallback becomes `COALESCE(mp.svc_track, 'main')`. `pick_machines_for_refill`'s eligibility predicates move to `svc_track` per F6; the centroid routing predicate stays on `venue_group`.
- **R6 (T6).** `SnapshotTab.tsx` only. Relabel the dashed-separator sink "PARTNER-FILLED (VOX concession)" and restrict it to `svc_track='vox'`. Add a separate "EXCLUDED FROM REFILL" section at the true end of the grid for `include_in_refill=false` machines, which must not render under the partner-filled header. Card quick-stats gain "N empty / M quasi" and the `s_gap` percent. Modal header gains `pct_ab_empty_or_quasi` and `hero_runway_days` next to runway. Stamp the card grid with the `app_cache.refreshed_at` age, since the grid reads the 60s-cached RPC while the modal reads live, and that mismatch is what surfaced this whole investigation. Fix the F4 chip comment and assert the chips sum to `p_score`.
- **R3b (T3b).** In the same migration as T3, realign `check_priority_surface_consistency()` to the new chip shape, so a currently-green invariant does not go red fleet-wide the moment T3 ships (F11, Q11). Exactly five same-shape edits inside its VALUES list, no new behaviour: `urgency_breakdown_sum`'s canonical moves from `mp.urgency` to `mp.p_score`; the `chip_capacity` and `chip_intents` rows are dropped, matching D7; `chip_runout`'s canonical stops using the leftover subtraction and becomes `round(pup.w_runout * COALESCE(mp.s_runout_hero,0), 2)`; a `chip_gap` row is added as `round(pup.w_gap * COALESCE(mp.s_gap,0), 2)`. Leave `chip_holes` and `chip_stale` alone, since both sides read `pick_urgency_params` and move together with the Q2 weight update. Leave the `service_track` row alone, since `mp.svc_track` is non-null for every machine carrying a priority row, so its `venue_group` fallback never fires in practice.
- **R7.** Cut. See Q4.

## 4. Candidate design

Cody and Dara confirm insertion points before anything is applied.

- **D1.** `v_lane_grain`: `SELECT vls.machine_id, vls.slot_name AS lane_id, vls.pod_product_id, vls.current_stock, vls.max_stock, i.dos, (i.dvel / NULLIF(i.facings,0)) AS lane_dvel, <grade CASE on lane_dvel>, <w CASE on grade>, (vls.current_stock::numeric / NULLIF(vls.max_stock,0)) AS fill_ratio, (vls.current_stock = 0) AS is_empty, (fill_ratio > 0 AND fill_ratio <= pp.quasi_fill_floor) AS is_quasi FROM v_live_shelf_stock vls JOIN v_shelf_sales_identity i ON i.machine_id = vls.machine_id AND i.pod_product_id = vls.pod_product_id CROSS JOIN pick_urgency_params pp WHERE vls.is_enabled AND NOT COALESCE(vls.is_broken,false) AND vls.is_eligible_machine AND vls.pod_product_id IS NOT NULL`. One row per physical facing. This join is the entire fix for 1a.
- **D2.** `v_machine_priority_base`'s `shelf_graded` and `magg` source `s_empty`, `s_lowfill`, `s_gap` and `empty_ab_count` from `v_lane_grain` grouped by `machine_id`, while `shelf_runout`, `worst_runout` and `breadth_runout` keep reading `v_shelf_sales_identity` at product grain exactly as today. Two grains coexist deliberately. Do not collapse them.
- **D3.** `s_gap` is a new aggregate over `v_lane_grain`: `100 * sum(w * (1 - COALESCE(fill_ratio,0))) / NULLIF(sum(w),0)`. `pct_empty_lanes` and `pct_quasi_lanes` are `100 * count(*) FILTER (...) / count(*)` over the same lane set; `pct_ab_empty_or_quasi` restricts to `grade IN ('A','B')`.
- **D4.** `hero_runway_days = COALESCE(min(dos) FILTER (WHERE grade='A'), min(dos) FILTER (WHERE grade='B'), min(dos) FILTER (WHERE grade='C'))` over `v_lane_grain`. `dos` is the product-level value repeated across each lane of that product (Q6), consistent with `lane_dvel` being a per-lane share rather than an independent per-lane velocity. `s_runout_hero = 100 * GREATEST(0, LEAST(1, (horizon_days - COALESCE(hero_runway_days, horizon_days)) / horizon_days))`, evaluated once at `hero_runway_days`, never averaged, and **never NULL**: a machine with no graded lane carrying a `dos` scores 0 on this term, which is correct because nothing in it is running out.
- **D5.** Worst-three mean: replace `avg(shelf_graded.shelf_runout) FILTER (WHERE grade IN ('A','B','C'))` with a `ROW_NUMBER() OVER (PARTITION BY machine_id ORDER BY shelf_runout DESC)` in a new CTE, then `avg(shelf_runout) FILTER (WHERE rn <= 3)` in `magg`.
- **D6.** `p_score` becomes the R3 sum inside `mscore`, reading `p.w_runout, p.w_gap, p.w_holes, p.w_expiry, p.w_stale`. `urgency` keeps its own separate `GREATEST(...)` computation, producing exactly the number it produces today. The P1/P2 tier CASE expressions in the outer SELECT, which currently re-derive `GREATEST(...)` inline twice, switch to reading the new `p_score` for their threshold tests.
- **D7.** `get_machine_health`'s `urgency_breakdown` drops the leftover-equals-runout subtraction (F4) and computes each chip directly as its own weighted term, so the chips are the literal addends of `p_score` and sum to it by construction. Drop the `'capacity'` chip, since `s_capacity` is not in the score; add a `'gap'` chip.
- **D8.** `pick_machines_for_refill`: swap the 6 eligibility predicates (F6, including the `'vox_emergency_offday'` tag) to `svc_track`, structure otherwise verbatim. Leave `vox_centroid` on `venue_group`. The off-day gate additionally swaps `runway_days` to `hero_runway_days`. `days_until_next_vox_day` is untouched.
- **D6b.** R3b's edit rides inside T3's migration and Cody reviews it alongside the `p_score` change, verbatim body before and after. Acceptance A11 is the gate: `check_priority_surface_consistency()` must still return 0 rows after T3 is applied.
- **D9.** Cut with T7. See Q4.

## 5. Open questions

**Resolved 2026-09-13:**

- **Q1.** `urgency` stays the old `GREATEST(...)` diagnostic. Only `p_score` becomes the blend. The chip-sum assertion targets `p_score`.
- **Q2.** Update the params table rather than hardcoding literals: `w_holes` 0.30 to 0.15, `w_stale` 0.13 to 0.08.
- **Q3.** The `'vox_emergency_offday'` reason tag keys on `svc_track`.
- **Q6.** `hero_runway_days` reuses the product-level `dos`, repeated per lane.
- **Q7.** A machine with no A-grade lanes (9 of 32 today, F10) walks down to B then C for its hero, and scores 0 on `s_runout_hero` if nothing graded carries a `dos`. It must never yield a NULL `p_score`. Measured note: applying the fallback changes no score today, because every B and C hero currently sits beyond the 4-day horizon. Its value is that it removes a NULL hazard that would otherwise drop 9 machines out of tiering entirely, and it will bite the day a B lane genuinely runs dry.
- **Q8.** No hard stop on the P1 count. CS accepts P1 above 12. P1 becomes a ranked queue and the picker takes the top 8 by score.
- **Q9.** The `s_gap` P1 override is 40, not 45, so ALJLT-1015-0200 (44.85), ALJLT-1015-0100 (44.38), NISSAN-0804 (44.32) and NOVO-1023 (40.99) are caught on the signal that identified them rather than incidentally or not at all.
- **Q10.** `stale_override_days` stays. A machine nobody has visited in 14 days may be P1 on staleness alone, because the ranking fix removes the real damage: JET-1016 falls from 92.86 and first place to 15.98 and eleventh, so it never again jumps the queue ahead of an emptier machine. Acceptance A6 is reworded to test what is actually guaranteed rather than a condition that cannot fail.

**Still open, answer at build start, read-only, before any migration:**

- **Q4. T7 is cut from this PRD.** The premise was wrong. `refill_instructions` has not been written to since 2026-06-08 and `suggested_product` has not been written since 2026-03-31 (F8). The suspected writer `engine_swap_pod` never touches the table; the real and only writer, `upsert_refill_stock_snapshot`, has never written `suggested_product` in any version. So there is no slot-normalisation mismatch and no stale version tag to find: the blank Suggestion column is a dead feature, not a broken join. Reconnecting it is a product question (where should lane suggestions come from now that this table is abandoned) and it gets its own PRD. It must not gate the priority fix. **Interim, carried into T6:** the modal's Suggestion column renders an explicit "no suggestion source" state rather than a silent dash, so nobody reads blank as "nothing to swap".
- **Q11. `check_priority_surface_consistency()` comes into scope as T3b.** It is green today across the whole fleet (F11), and T3 plus D7 would turn 3 of its 11 checks red on every machine: `urgency_breakdown_sum` compares against `mp.urgency` while the chips now sum to `p_score`; `chip_capacity` and `chip_intents` compare a chip D7 removes against a canonical that stays non-zero; and `chip_runout` still uses the leftover subtraction. Surgical-only exists to block unrelated refactors, not to force shipping a change that knowingly turns its own passing invariant red. The edit is five lines in a VALUES list, in T3's own migration, under Cody review, gated by A11.
- **Q5.** After T2 and T3 ship, which of `empty_wt_a/b/c/d`, `w_empty` (0.945), `w_lowfill` (0.5), `w_capacity` (0.10) and `w_intents` (0) still have a reader? `s_empty` and `s_lowfill` survive as exposed diagnostics and feed the `empty_ab_count` override, but they are not addends of the new `p_score`: `s_gap` subsumes both by construction, since a lane at zero and a lane at 20% both contribute their full weighted shortfall to the gap. Answered 2026-09-14: `empty_wt_a/b/c/d` has exactly one reader today (`v_machine_priority`'s `shelf_graded`) and loses it at T2. `w_empty`, `w_lowfill`, `w_capacity` and `w_intents` each have two readers today (`get_machine_health`'s chips and `check_priority_surface_consistency`) and lose the first at D7 and the second at R3b. All five go fully dark. Per the standing default they stay in place, forward-only per Article 12, marked inert via `COMMENT ON COLUMN` in T3's migration. Do not drop them.

## 6. Constraints

Surgical only, nothing beyond T1 to T7. Cody review before applying any canonical-writer, view or trigger change, with verbatim bodies before and after in the review. Every migration gets a git file committed immediately, no batching. Filename `YYYYMMDDHHMMSS_snake_case_name.sql`, forward-only per Article 12: `DROP FUNCTION` plus `CREATE OR REPLACE`, never edit-in-place. Check `pg_proc` and view column lists for overload or shape drift before replacing anything whose signature changed. `.limit(10000)` on any Supabase query returning more than 100 rows. RLS uses `(SELECT auth.uid())`, never bare. Run `preflight_refill_plan` before any commit that touches a live plan date. Never force-push. If live state contradicts F1 to F10, stop and report rather than improvise.

## 7. Acceptance

Measured against live data 2026-09-13 with all four decisions applied. These are the numbers the build must reproduce, not projections.

- **A1.** `s_empty > 0` on every machine with at least one lane at `current_stock = 0`. ACTIVATEMCC-1037 lane A10 (Aquafina 0 of 17) yields `s_empty > 0` and `empty_ab_count >= 1`.
- **A2.** VML-1003-0400-O1, MINDSHARE-1009-4500-O1, ALJLT-1015-0200-O1 and NISSAN-0804-0000-L0 all leave `P3_OK`. Expected: all four reach P1, VML and MINDSHARE and ALJLT-1015-0200 via the `s_gap >= 40` override, NISSAN via that override and `holes_A`.
- **A3.** JET-1016-0000-O1 does not outrank any machine with `s_gap >= 40`. Expected `p_score` 15.98, eleventh in fleet, against USH 67.04, VOXMM-1013 58.39, ACTIVATEMCC-1037 56.37, VOXMCC-1005 56.04, WPP-1002 30.18, VML-1003 28.08, MINDSHARE-1009 18.64, NISSAN 18.30.
- **A4.** ACTIVATEMCC-1037 appears in the main P1 list and is counted by the "P1 restock" pill.
- **A5.** `pick_machines_for_refill` on a Sunday returns ACTIVATEMCC-1037 as eligible.
- **A6.** A machine may be P1 on staleness alone (Q10), but must never rank above any machine with `s_gap >= 40`. JET-1016 satisfies this at `p_score` 15.98. The test is generic; do not pin it to JET's fill percentage, which drifts with normal sales (71.51% when Section 7 was measured, 70.97% a day later).
- **A7.** No machine ends with a NULL `p_score`, including the 9 with zero A-grade lanes (F10).
- **A8.** The `urgency_breakdown` chips sum exactly to `p_score` for every machine.
- **A9.** The top 8 by `p_score`, which is what the picker takes, comes out as: USH-1008 67.04, VOXMM-1013 58.39, ACTIVATEMCC-1037 56.37, VOXMCC-1005 56.04, WPP-1002 30.18, VML-1003 28.08, GRIT-1022 20.06, WAVEMAKER-1006 19.56.
- **A10.** Every migration has a committed git file, and `preflight_refill_plan` ran before any commit touching a live plan date.
- **A11.** `check_priority_surface_consistency()` returns 0 rows after T3 and T3b are applied, the same as it does today (F11). A non-empty result blocks the build.

**Expected tier distribution: 17 P1, 0 P2, 15 P3.** P2 is empty because every machine scoring at or above `p2_threshold` 18 is already caught by an override. This is a known and accepted consequence of Q8 and Q9: the tier label degrades to near-binary and the `p_score` ranking carries the real signal. If a future tuning pass wants a meaningful P2, raise `p1_gap_min` rather than `p2_threshold`.

Full 32-machine before and after (old `p_score` / old tier, new `p_score` / new tier):

| Machine                  | Fill% | Old       | New      |
| ------------------------ | ----- | --------- | -------- |
| USH-1008-0000-W1         | 52.31 | 77.00 P1  | 67.04 P1 |
| VOXMM-1013-0101-B0       | 60.09 | 100.00 P1 | 58.39 P1 |
| ACTIVATEMCC-1037-0000-L0 | 52.46 | 41.65 P1  | 56.37 P1 |
| VOXMCC-1005-0201-B0      | 57.09 | 66.67 P1  | 56.04 P1 |
| WPP-1002-4300-O1         | 51.43 | 46.67 P1  | 30.18 P1 |
| VML-1003-0400-O1         | 45.78 | 4.67 P3   | 28.08 P1 |
| GRIT-1022-0100-W0        | 56.55 | 20.00 P2  | 20.06 P1 |
| WAVEMAKER-1006-4100-O1   | 56.67 | 33.33 P1  | 19.56 P1 |
| MINDSHARE-1009-4500-O1   | 55.66 | 4.67 P3   | 18.64 P1 |
| NISSAN-0804-0000-L0      | 56.91 | 6.25 P3   | 18.30 P1 |
| JET-1016-0000-O1         | 71.51 | 92.86 P1  | 15.98 P1 |
| AMZ-1038-3001-O1         | 69.68 | 0.00 P3   | 13.95 P1 |
| ALJLT-1015-0200-O1       | 56.00 | 0.00 P3   | 13.46 P1 |
| ACTIVATE-2005-0000-W0    | 74.66 | 0.00 P3   | 13.42 P1 |
| AMZ-1046-2406-O1         | 73.53 | 4.38 P3   | 13.32 P3 |
| ALJLT-1015-0100-B1       | 59.02 | 0.00 P3   | 13.31 P1 |
| NOVO-1023-0000-W0        | 67.28 | 0.00 P3   | 12.30 P1 |
| AMZ-1029-3003-O1         | 75.47 | 0.00 P3   | 12.13 P3 |
| OMDCW-1021-0100-W0       | 73.13 | 4.38 P3   | 11.75 P3 |
| IRIS-1070-0000-O1        | 70.05 | 0.00 P3   | 9.94 P3  |
| VML-1004-0500-O1         | 72.46 | 0.00 P3   | 8.84 P3  |
| AMZ-1068-2401-O1         | 68.91 | 0.00 P3   | 8.65 P3  |
| MPMCC-1058-0000-R0       | 73.30 | 0.00 P3   | 8.56 P3  |
| AMZ-1057-2403-O1         | 67.32 | 0.00 P3   | 8.56 P3  |
| VOXMCC-1011-0101-B0      | 75.30 | 0.00 P3   | 7.97 P3  |
| ADDMIND-1007-0000-W0     | 69.30 | 0.00 P3   | 7.96 P3  |
| MPMCC-1054-0000-M0       | 77.63 | 0.00 P3   | 6.41 P3  |
| MC-2004-0100-O1          | 79.89 | 26.67 P2  | 6.13 P3  |
| IFLYMCC-1024-0000-W0     | 80.83 | 0.00 P3   | 5.54 P3  |
| HUAWEI-2003-0000-B1      | 75.26 | 0.00 P3   | 5.42 P3  |
| NOOK-1019-0200-B1        | 81.57 | 0.00 P3   | 4.30 P3  |
| OMDBB-1020-0P00-O1       | 89.71 | 0.00 P3   | 3.17 P3  |

## 8. Out of scope

Any change to the `s_expiry` or `s_stale` formulas; only their weight in the blend moves. Any repair of the `refill_instructions` suggestion path, which is cut per Q4 and gets its own PRD. Any change to `upsert_refill_stock_snapshot`. Any drift-detector change beyond R3b's five listed VALUES edits. Any dashboard beyond `SnapshotTab.tsx`. Route and geography clustering beyond the eligibility swap (F6's routing bucket stays on `venue_group`). Backfilling `service_model` for any machine beyond the 3 named `-V0` units. Any change to `include_in_refill` for any machine: the `-V0` machines stay `false` before and after, T5 only tags their `service_model`. Raising `holes_norm` or `p1_holes_min` to offset the `hole_frac` increase, which Q8 explicitly declines. Re-tuning `p1_gap_min` after the first live week, which is a separate pass.

---

## /goal invocation

Rev 2. Step 1 is already complete and its findings are folded into F3, F8, F11, Q4, Q5 and Q11. Resume at step 2.

```
/goal Resume docs/prds/PRD-122-lane-grain-priority.md (Rev 2) on Supabase eizcexopcuoycuosittm
(boonz-erp, main). Your step-1 findings were verified and are now folded into the PRD: F3 (base is a
CTE), F8 + Q4 (refill_instructions abandoned), F11 + Q11 (check_priority_surface_consistency), Q5
(five inert params). Do NOT re-run step 1 and do not re-litigate any resolved Q.
TWO SCOPE CHANGES since you halted:
  - T7 is CUT. refill_instructions is a dead table, not a broken join, so there is nothing to
    reconnect. It gets its own PRD later. The only remnant is in T6: render an explicit
    "no suggestion source" state in the modal's Suggestion column instead of a silent dash.
  - T3b is ADDED. Realign check_priority_surface_consistency() inside T3's own migration, exactly the
    five VALUES edits listed in R3b, no more. It returns 0 rows today and must still return 0 rows
    after T3 (acceptance A11).
ORDER:
(2) Dara designs v_lane_grain (D1) and the pick_urgency_params column additions (R1).
(3) Cody reviews v_lane_grain, the rebuilt v_machine_priority, pick_machines_for_refill,
    get_machine_health, check_priority_surface_consistency, and the machines.service_model migration.
    Verbatim bodies before and after. BEFORE applying any of them.
(4) Apply T1-T5 in order, one migration per item, each its own committed git file, each verified
    inside a rolled-back transaction first. T3b rides in T3's migration.
(5) Before applying T3, print the full 32-machine before/after tier table and diff it against
    Section 7. There is NO hard stop on the P1 count (Q8), but any machine whose new tier differs
    from Section 7 must be explained before proceeding.
(6) T6 (SnapshotTab.tsx) only after T1-T5 are live and stable.
(7) Verify acceptance A1-A11. A11 is a hard gate: a non-empty
    check_priority_surface_consistency() blocks the build.
CONSTRAINTS: Section 6, all in force. Surgical only. If live state contradicts F1-F11, or a
resolved-Q answer contradicts the candidate design, STOP and report. Do not improvise.
DONE: diff summary mapped to T1-T6 plus T3b, acceptance results, then STOP.
```
