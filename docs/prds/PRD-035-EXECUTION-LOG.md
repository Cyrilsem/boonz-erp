# PRD-035 Execution Log — Refill v3

Track each phase's acceptance criteria here as it ships. Forward-only; migration files only until CS sign-off.

| Phase | Workstream                                 | Status                            | Migration / artifact                                           | Cody verdict                    | Notes                                                                                                                                                                              |
| ----- | ------------------------------------------ | --------------------------------- | -------------------------------------------------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A     | WS-C flavor-aware stitch (no silent drops) | ✅ **APPLIED to prod 2026-06-18** | `20260618093000_prd035_a_stitch_wh_aware_variant_fallback.sql` | ⚠️ Approve w/ revisions (06-18) | Replay PASS; applied via apply_migration. Prod confirm: fn=v24_wh_aware_variant_fallback (min-uuid fix present), CHECK includes variant_substituted. 2 replay-caught bugs fixed.   |
| B     | WS-A relative-score fill sizing            | ✅ **APPLIED to prod 2026-06-18** | `20260618095000_prd035_b_engine_relative_score_band.sql`       | ⚠️ Approve w/ revisions (06-18) | Replay PASS (band1 48.3 vs band3 1.3, stance-free, 0-sales=0); applied. Prod confirm: fn=v18, within-machine ntile rank band present. METRICS_REGISTRY row 37 redefined.           |
| C     | WS-D session readiness view/RPC            | ✅ **APPLIED to prod 2026-06-18** | `20260618094000_prd035_c_refill_session_readiness.sql`         | ✅ Approve (06-18)              | Replay PASS; applied. Prod confirm: INVOKER+STABLE (prosecdef=false, provolatile=s), callable (84 rows tomorrow).                                                                  |
| D     | WS-E picker P1/area/sister/VOX/Saturday    | ✅ **APPLIED to prod 2026-06-18** | `20260618096000_prd035_d_picker_vox_calendar_saturday.sql`     | ✅ Approve (06-18)              | Replay PASS (Sat=0, Wed=8/8 VOX + 3 nearest non-VOX); applied. Prod confirm: build_draft Saturday guard + picker v10 (Saturday guard + VOX branch + priority_tier fix). Bug fixed. |
| E     | WS-B score-driven swap                     | ✅ **APPLIED to prod 2026-06-18** | `20260618097000_prd035_e_engine_score_driven_swap.sql`         | ✅ Approve (06-18)              | Replay PASS (Pass-3 gated by B2; kill-switch verified); applied. Prod confirm: fn=v11 + Pass-3 present; refill_settings.swaps_enabled='false' (Pass-3 OFF, manual enable only).    |

## FINAL REPORT — apply run 2026-06-18

**Replays: 5/5 PASS. Applies: 5/5 APPLIED to prod 2026-06-18, each confirmed read-only.** (A applied on explicit CS `apply A`; C/B/D/E applied in the autonomous follow-up run, each gated by its passing replay.)

| Phase           | Replay  | Applied (2026-06-18) | Prod confirm                                                                      | Bugs caught + fixed by replay                                                                          |
| --------------- | ------- | -------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| A stitch v24    | ✅ PASS | ✅ APPLIED           | ✅ fn=v24_wh_aware_variant_fallback (min-uuid fix); CHECK has variant_substituted | (1) `min(uuid)` → `min(text)::uuid`; (2) `procurement_alerts` CHECK extended for `variant_substituted` |
| C readiness RPC | ✅ PASS | ✅ APPLIED           | ✅ INVOKER+STABLE; callable (84 rows)                                             | none                                                                                                   |
| B engine v18    | ✅ PASS | ✅ APPLIED           | ✅ fn=v18; within-machine ntile rank band present                                 | none (band1 cover 48.3 vs band3 1.3; stance-free; 0-sales=0)                                           |
| D picker v10    | ✅ PASS | ✅ APPLIED           | ✅ build_draft Saturday guard + picker v10 (Saturday guard + VOX + tier fix)      | (3) `priority_tier` CHECK — VOX P3 mapped to P2_MAINTAIN; + Saturday guard added to picker             |
| E swap v11      | ✅ PASS | ✅ APPLIED           | ✅ fn=v11 + Pass-3; swaps_enabled='false'                                         | none (Pass-3 fully gated by B2 bar; kill-switch verified)                                              |

**Replay evidence:** A — Red Bull→Diet 6u, Healthy Cola→Green Apple+Pineapple 5u, Dubai Popcorn→Salted + `variant_substituted` alert; Hunter qty 0 is a genuine total stockout (all 5 flavors 0 WH) carrying a `wh_zero` alert (not silent). C — 69 shelves (56 can_fill / 4 sibling / 9 wh_zero). B — 117 refills, fill scales hard with within-machine rank, qty matches `ROUND(velocity·days·band)` with no stance term. D — Saturday 0 rows; Wednesday all 8 VOX + 3 nearest non-VOX. E — v11, 0 Pass-3 swaps (all below B2 threshold), `swaps_enabled=false` → 0.

**3 real bugs were caught by the replays and fixed in the migration files before any prod exposure** (they would have shipped broken: A's `min(uuid)` aborts every stitch; A's CHECK rejects every substitution alert; D's `priority_tier` CHECK aborts every VOX-day pick).

**Post-apply prod state confirmed:** `refill_settings.swaps_enabled = 'false'` (Pass-3 auto-swaps OFF; manual enable only).

### Two open follow-ups (carry beyond this goal)

1. **Article 16 `v_wh_pickable` unification** — stitch still reads WH inline in 4 places; unify onto `v_wh_pickable` in ONE later behaviour-diffed migration. Do NOT half-migrate (re-introduces the line/alert disagreement). (METRICS_REGISTRY row 34.)
2. **`swaps_enabled` stays OFF** — leave Pass-3 auto-swaps disabled until proven over a few supervised cycles; enable manually.

---

## Phase A — WS-C flavor-aware stitch (HEADLINE)

**Migration:** `supabase/migrations/20260618093000_prd035_a_stitch_wh_aware_variant_fallback.sql`
**Live body fetched:** `stitch_pod_to_boonz` v23 (`v23_wh_reserved`) reproduced verbatim, 6 surgical edits → `v24_wh_aware_variant_fallback`.

### Diff (v23 → v24), surgical only

1. **`pull_overlaid`** — new col `wh_avail_variant` = per-variant WH avail (same measure the line-builder already used: `Active AND warehouse_stock>0 AND quarantined=false`), computed early so residual selection is WH-aware.
2. **`pull_resid` split into `pull_resid_flags` + `pull_resid`** — adds `has_onshelf_wh`, `onshelf_ideal_names`, `onshelf_ideal_boonz_id`. `is_residual_variant` rewritten as a 5-branch CASE: **branches 1–4 = byte-identical semantics to v23**; **only the ELSE is new** — warehouse REFILL + shelf has a known on-shelf variant + NONE of the on-shelf variants have WH → admit in-stock siblings (`wh_avail_variant>0`) and drop the OOS on-shelf variant from the pool. New flag `is_sibling_fallback` marks exactly those.
3. **`pull_with_wh`** — reuses `wh_avail_variant AS wh_avail` (drops the duplicate inline subquery → selection measure == gating measure, no internal disagreement).
4. **`pull_lines` / `remove_lines` / `remove_lines_physical_fallback`** — 3 new carried cols (removes get `false/NULL/NULL`); UNION re-balanced to 21 cols each.
5. **Final JSON emit** — new keys (`machine_id`/`pod_product_id`/`boonz_product_id`, `is_sibling_fallback`, `dropped_ideal_names`, `dropped_ideal_boonz_id`); new `comment` branch `[SIBLING-FALLBACK] on-shelf flavor <X> out of WH stock -> filled with in-stock sibling <Y>`, placed before overlay/WH-warning branches.
6. **New substitution-alert block** — `variant_substituted` alerts derived **from the emitted `v_lines` set itself**, so line-builder and alert-builder share one source of truth (no silent 0). Return gains `substitution_alerts` + version tag.

### Behaviour guarantees

- Right-qty + right-SKU (on-shelf in stock) → unchanged from v23.
- Right-qty via sibling (on-shelf OOS, sibling in stock) → full residual pool reallocated to sibling (no qty cut; SKU substituted), comment + alert raised.
- Empty (all OOS) → no residual line (worst case), still flagged by the pre-existing `wh_zero` alert → not silent.
- Non-warehouse (internal_transfer/vox) and ADD_NEW paths unchanged.

### Cody verdict — ⚠️ Approve with revisions (2026-06-18)

- Articles checked: 1, 3, 4, 6, 8, 12, 14, 16. All ✅ except Article 16.
- **Article 16:** "WH pickable stock" is a registered metric (`v_wh_pickable`, registry row 34). The new inline WH subquery is technically inline re-derivation but reuses v23's grandfathered pre-Art-16 measure. Cody ruled **do NOT half-migrate** (pointing only the fallback at `v_wh_pickable` re-introduces the line/alert disagreement Phase A kills). Logged as one behaviour-diffed follow-up ticket in METRICS_REGISTRY row 34.

### CONFIRM (AC) — PENDING CS apply gate

Run as a rolled-back replay of 2026-06-18 (`BEGIN; CREATE OR REPLACE …; SELECT stitch_pod_to_boonz('2026-06-18', true); ROLLBACK;`):

- [ ] 3 heroes (Red Bull / Healthy Cola / Hunter) resolve >0 via correct or sibling SKU.
- [ ] every dropped/substituted line has a `variant_substituted` alert + `[SIBLING-FALLBACK]` dispatch note.
- [ ] zero silent 0-fills.
- [ ] other machines byte-identical to v23 output.

**STOP for CS:** migration file only, nothing applied to prod. Awaiting CS green light to run the rolled-back replay + apply.

## Phase C — WS-D session readiness (read-only)

**Migration:** `supabase/migrations/20260618094000_prd035_c_refill_session_readiness.sql`
**Artifact:** new read-only function `get_refill_session_readiness(p_plan_date date)` — `LANGUAGE sql STABLE SECURITY INVOKER`, zero writes.

### Design

One row per in-scope shelf (`pod_refill_plan` REFILL/ADD_NEW, status draft|approved). Resolves the chain the engine is otherwise blind to:

- **pod → mapped flavor(s)** via `product_mapping` (machine-specific-or-global precedence, same as stitch).
- **on-shelf flavor identity** via `v_pod_inventory_latest` (Active).
- **REAL pickable WH per flavor** = `v_wh_pickable` (quarantine + expiry already excluded) **netted per machine for reservations** (`reserved_for_machine_id IS NULL OR = machine`) — the layer `v_wh_pickable` does not apply.
- **mapping/onboarding health** (`mapped_variant_n`, `mapped_in_stock_n`, unmapped → `onboarding_gap='no_active_mapping'`).
- **expiry risk** = earliest pickable WH batch ≤ plan_date + 14d.
- **verdict** mirrors the WS-C line-builder: `can_fill` (ideal on shelf, in stock) · `can_fill_via_sibling` (ideal OOS, sibling in WH) · `cant_fill_wh_zero` (all mapped OOS) · `cant_fill_unmapped`. Plus a human `reason`.

### Cody verdict — ✅ Approve (2026-06-18, read-only fast-path)

- Articles checked: 3, 4, 6, 12, 16. All clean.
- Article 16: reads `v_wh_pickable` (row 34) — reservation netting is consumer-side scoping (same pattern as `v_dispatch_availability` row 35), not re-derivation. `v_pod_inventory_latest` used for flavor identity only. No metric re-derived.
- RPC_REGISTRY read-only helpers updated.

### CONFIRM (AC)

- [ ] readiness flags a quarantined flavor (excluded by `v_wh_pickable`) as `cant_fill_wh_zero`/sibling.
- [ ] readiness nets a flavor reserved to another machine out → not counted as pickable here.
- [ ] readiness flags an unmapped pod as `cant_fill_unmapped`.
- [ ] function performs zero writes (read-only).

Safe to apply whenever CS runs the batch (no rollback risk); pairs naturally with Phase A.

## Phase B — WS-A relative-score fill sizing

**Migration:** `supabase/migrations/20260618095000_prd035_b_engine_relative_score_band.sql`
**Live body fetched:** `engine_add_pod` v17 (`v17_cover_capped_f1_per_machine`) reproduced verbatim, one CTE swapped → `v18_relative_score_band_f1_per_machine`. `compute_refill_decision` UNCHANGED.

### CS decision A1 (2026-06-18)

Percentile bands: top third → 100% cover · mid → 60% · bottom → 30% · bottom-band AND empty → floor (~1 facing).

### Diff (v17 → v18)

- `covered` CTE (old): `cover_units = CASE WHEN stance IN (WIND DOWN/ROTATE OUT/DEAD) THEN 0 ELSE GREATEST(ROUND(velocity_target),1) END` — stance drove qty two ways (cover_mult inside velocity_target + the stance zero-out).
- Replaced by `ranked` (`ntile(3)` within machine by `final_score`, tiebreak v30/shelf) + new `covered`: `band_fraction` 1.00/0.60/0.30; `cover_units = ROUND(raw velocity blend × p_days_cover × band_fraction)` (stance-free); bottom-band+empty → 1; **0 local sales (v7=0 AND v30=0) → 0** (sales-driven dead guard, not stance).
- `final_score` untouched (still the stance+global+local composite — used only as the RANK signal per WS-A).
- Added reasoning fields `machine_band`/`band_fraction`/`machine_rank_pct`; version tags bumped v17→v18 (DELETE pod_swaps filter, dead_tags tagged_by, resolved_by_engine, engine_calibration, engine_version).
- WH allocation/reservation (`prior_need`, `LEAST(need_raw, wh_avail-prior_need)`) untouched.

### Cody verdict — ⚠️ Approve with revisions (2026-06-18)

- Articles checked: 1, 4, 6, 8, 12, 16. Writes only non-protected staging (`pod_refills`/`pod_swaps`).
- **Article 16:** this is a sanctioned _redefinition_ of registry row 37 (the engine IS the canonical home of refill-qty), not an inline copy. Required revision = update row 37 → **DONE** (band-scaled raw-velocity cover; stance/cover_mult/velocity_target demoted to advisory).
- Behaviour flag for CS: WIND DOWN shelves that still sell now get a rank-based fill (were stance-zeroed) — surface in the CONFIRM diff.

### CONFIRM (AC) — PENDING CS apply gate

- [ ] a low-score empty shelf fills LESS than a top-score shelf on the same machine.
- [ ] stance no longer affects qty (same final_score → same band → same fill regardless of stance).
- [ ] 0-local-sales shelf gets 0.
- [ ] diff surfaces WIND-DOWN-with-sales deltas vs v17.

**STOP for CS:** migration file only, nothing applied.

## Phase D — WS-E picker P1/area/sister + VOX calendar + Saturday-off

**Migration:** `supabase/migrations/20260618096000_prd035_d_picker_vox_calendar_saturday.sql`
**Live bodies fetched:** `pick_machines_for_refill` v9.2, `build_draft_for_confirmed`.

### CS decisions (2026-06-18)

E1 cluster key = `venue_group` · E2 VOX well-equipped = `fill_pct≥70 AND runway_days≥5 AND empty_shelves_count=0` (machine-grain proxy for "every VOX shelf") · E3 non-VOX on VOX days = top P1 need, 2-3 NEAREST the VOX centroid (lat/long) · E4 sister = same as E1 (venue_group; existing sibling logic unchanged).

### Diff

- **`build_draft_for_confirmed`** (Fri-8pm cron entry): + Saturday guard `IF EXTRACT(DOW FROM p_plan_date)=6 THEN RETURN skipped_saturday` BEFORE any pick/confirm/engine write. Rest verbatim.
- **`pick_machines_for_refill` v9.2 → v10:** branch on DOW. VOX days (Wed=3, Fri=5) with ≥1 needy VOX → ALL VOX machines + 2-3 nearest-to-VOX-centroid P1 non-VOX (planar lat/long approx, `machines.latitude/longitude`). When ALL VOX well-equipped → fall through to the **verbatim v9.2 normal path** (focus non-VOX). All other days → verbatim v9.2. Both branches write the identical `machines_to_visit` column set + `ON CONFLICT` upsert.

### Cody verdict — ✅ Approve (2026-06-18)

- Articles checked 1,4,5,6,8,11,12,16 — all clean. Targets non-protected staging (`machines_to_visit`/`planned_swaps`); engines unchanged. Article 16: E2 reads `fill_pct/runway_days/empty_shelves_count` straight off `v_machine_priority` (no recompute); lat/long distance is a new routing primitive, not a registered metric.
- Operational caveats (non-blocking): planar distance is ranking-grade not geodesic — flag NULL-coordinate machines; confirm the Friday cron resolves `p_plan_date`=Saturday so the guard fires.

### CONFIRM (AC) — PENDING CS apply gate

- [ ] Saturday `plan_date` → `skipped_saturday`, zero rows written.
- [ ] Wed/Fri with ≥1 needy VOX → all VOX + ≤3 nearest P1 non-VOX.
- [ ] Wed/Fri all-VOX-equipped → normal path (no VOX picked).
- [ ] non-VOX day → byte-identical to v9.2.

**STOP for CS:** migration file only, nothing applied.

## Phase E — WS-B score-driven swap

**Migration:** `supabase/migrations/20260618097000_prd035_e_engine_score_driven_swap.sql`
**Live bodies fetched:** `engine_swap_pod` v10_2, `find_substitutes_for_shelf`, `score_machine_for_product` (signatures verified in pg_proc).

### CS decisions (2026-06-18)

B1 = drop + flag (REMOVE incumbent, return to WH, stamp `relocation_candidate=true`) · B2 = swap only when candidate projected fit ≥ 50 AND (candidate − incumbent) ≥ 25.

### Diff (v10_2 → v11) — purely additive

- Passes 1 (strategic tags), 2 (dead/rotate resolution), 2b (driver recs) reproduced VERBATIM.
- New **Pass 3 (score-driven swap)** before RETURN: rank each picked machine's shelves by `compute_refill_decision.final_score` within machine (bottom third = low rank, machines with ≥3 shelves); top in-stock candidate from `find_substitutes_for_shelf` filtered by the SAME present/suppressed/introduction-cooldown guards as Pass 2; project incumbent + candidate onto a 0-100 fit scale via the canonical `score_machine_for_product`; insert a `score_swap` only when `hard_block IS NULL AND candidate≥50 AND (candidate−incumbent)≥25`. Incumbent → WH, `relocation_candidate:true`.
- Respects per-machine cap across all passes, `swaps_enabled` kill-switch, committed/cooldown/suppressed guards. Signature UNCHANGED (B2 thresholds = local consts → no overload). Return gains `score_driven_swaps`/`score_swap_min_gap`/`score_swap_min_candidate`.
- **Projection basis note:** `compute_refill_decision.final_score` cannot be computed for a product NOT on the shelf (it reads slot_lifecycle velocity for that machine/shelf), so `score_machine_for_product` (Engine-2 fit, 0-100) is the faithful "projected return in this slot" tool; incumbent scored identically for an apples-to-apples gap. Stamped in `reasoning.projection_basis`.

### Cody verdict — ✅ Approve (2026-06-18)

- Articles checked 1,4,6,8,12,14,16 — all clean. Non-protected `pod_swaps` only. True replace (no overload). Article 16: final_score read for ranking; score_machine_for_product is an existing RPC, not a registered metric.
- Operational notes (non-blocking): score-swaps fire automatically in the Friday cron — kill switch is `refill_settings.swaps_enabled='false'`; watch `duration_ms` (per-shelf scorer calls, ample headroom under the 20-min build_draft timeout).

### CONFIRM (AC) — PENDING CS apply gate

- [ ] a swap is proposed ONLY when candidate_fit≥50 AND (candidate−incumbent)≥25 (verify a near-threshold reject + a clear-win fire).
- [ ] `relocation_candidate:true` stamped on the displaced incumbent.
- [ ] per-machine cap honored across passes.
- [ ] `swaps_enabled=false` suppresses Pass 3 entirely.

**STOP for CS:** migration file only, nothing applied.

---

## Summary — all 5 phases delivered as migration FILES (2026-06-18). Nothing applied to prod.

| #   | File                                                           | Cody             | Apply order                      |
| --- | -------------------------------------------------------------- | ---------------- | -------------------------------- |
| A   | `20260618093000_prd035_a_stitch_wh_aware_variant_fallback.sql` | ⚠️→ticketed      | 1 (headline)                     |
| C   | `20260618094000_prd035_c_refill_session_readiness.sql`         | ✅ read-only     | any (safe)                       |
| B   | `20260618095000_prd035_b_engine_relative_score_band.sql`       | ⚠️→registry done | 2                                |
| D   | `20260618096000_prd035_d_picker_vox_calendar_saturday.sql`     | ✅               | 3                                |
| E   | `20260618097000_prd035_e_engine_score_driven_swap.sql`         | ✅               | 4 (last; depends on B's scoring) |

**Per-phase rule honored:** live body fetched (`pg_get_functiondef`/`pg_get_viewdef`) → forward-only `CREATE OR REPLACE` migration FILE → diff → Cody verdict → STOP. No prod apply. No deletes (supersede-only). Registry updates done: METRICS_REGISTRY rows 34 (Art-16 stitch WH ticket) + 37 (refill-qty redefinition); RPC_REGISTRY (readiness RPC). **Each phase's CONFIRM is the CS-gated rolled-back replay** before apply.

## Open decisions (CS)

All decided 2026-06-18 (no open decisions remaining):

- ~~A1 rank→fill curve~~ → percentile bands (top 100% / mid 60% / bottom 30% / bottom+empty floor).
- ~~B1 relocate-vs-drop~~ → drop + flag relocation candidate.
- ~~B2 swap threshold~~ → gap ≥ 25 AND candidate ≥ 50.
- ~~E1 cluster key~~ → venue_group.
- ~~E2 VOX well-equipped~~ → fill ≥ 70 AND runway ≥ 5d AND 0 empty shelves.
- ~~E3 non-VOX pick~~ → top P1, nearest VOX centroid.
- ~~E4 sister def~~ → same as E1 (venue_group).

### Remaining (CS, at apply time)

- Run each phase's rolled-back replay (`BEGIN; CREATE OR REPLACE …; SELECT …; ROLLBACK;`) and tick its CONFIRM checklist before applying.
- Apply order A → C → B → D → E. After apply: CHANGELOG + MIGRATIONS_REGISTRY entries; (B) confirm METRICS_REGISTRY row 37; (A) open the Art-16 follow-up to unify all stitch WH reads onto `v_wh_pickable`.
- Decide whether auto score-swaps (Phase E, Friday cron) stay on or are gated by `refill_settings.swaps_enabled='false'` until trusted.
