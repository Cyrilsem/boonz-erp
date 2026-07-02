# PRD-020 — 08-09 Jun refills + 05-06 Jun close-out (Simran answers)

Status: Closed 2026-07-03 (PRD-072 sweep). Reason: historical, executed June 2026; Performance-tab remnant shipped via PRD-072. Reopen by deleting this line.

**Owner:** Claude Code · **Created:** 2026-06-10 · Supabase `eizcexopcuoycuosittm`
**Format:** engineering build-spec (PRD-017/018/019 discipline). Two parts: (A) close the 05-06 Jun WIP items now that Simran answered; (B) the new 08/06 + 09/06 round. Carry all §constraints.
Already logged — DO NOT redo: 01-02 Jun (PRD-017), 03-04 Jun (PRD-018), 05-06 Jun green/DONE rows (PRD-019). This PRD = the 05-06 **leftovers** + **08/06 + 09/06 only**.

## Driver-recommendation policy (CS decision 2026-06-10)

"Recommendation from driver on the ground" = a REQUEST for next refill, NOT a completed action. Write each to `driver_recommendations` (and/or `driver_feedback`) as a signal for the next engine run via the canonical driver-rec writer. NEVER log a recommendation as a completed refill. Only the "Error in the Data / log the flow" lines and the Part-A close-out lines are real placements to log.

---

## PART A — 05-06 Jun close-out (Simran's red answers)

These six lines were SKIPPED/PARKED in PRD-019 for bad dates or unconfirmed qty. Simran has now answered. Log each as a normal placement on its ORIGINAL visit date (AMZ-1029 + NOOK = **2026-06-05**; Vox 0795/0797 = **2026-06-06**, source_origin `vox_at_venue`). Dedup keys on machine+date+boonz+qty+action+shelf, so re-logging onto the same visit is safe.

- **AMZ-1029-3003-O1 (dev 0745)** A10 — **Hunter - Sea Salt & Cider Vinegar 1 @ 2027-02-01** (was wrongly 01/02/26).
- **AMZ-1029-3003-O1** A11 — **Dubai Popcorn Salted 3 @ 2027-02-17** (was wrongly 17/02/26).
- **AMZ-1029-3003-O1** A16 — **Vitamin Well - Reload 2 @ 2026-08-30** (was invalid 30/02/26).
- **NOOK-1019-0200-B1** A15 — **Eviron - Wellness Drink 4 @ 2027-04-29** + **G&H Popped Protein - Salt & Black Pepper 3 @ 2026-08-26** (qty now confirmed: Eviron 4, G&H 3).
- **VOXMCC-1011-0101-B0 (Vox 0795)** — **Vitamin Well - Care 2 @ 2026-09-06** [vox_at_venue].
- **VOXMCC-1005-0201-B0 (Vox 0797)** — **Vitamin Well - Care 2 @ 2026-09-06** [vox_at_venue].

**Still open (do NOT log):**

- AMZ-1029 A6 **Smart Gourmet - Classic Humus +2 — product N/A**, stays parked to procurement (keep the existing action_tracker row open).

**Close (resolve, no DB write):**

- Mirdif Stockroom list — Simran confirmed "for my notes", intentionally not in system → resolve/close its action_tracker note. The three date-fix action_tracker rows (Hunter S&V, Dubai Salted, VW Reload) and the NOOK qty row → mark `resolved` once their lines above are logged.

---

## PART B — 08/06 + 09/06 round

### B1 — Physical actions to LOG ("Error in the Data / log the flow")

- **AMZ-1068-2401-O1 (Amazon 0705, dev 0705)** — date **2026-06-08**: **REMOVE 1 Sabahoo @ 2026-06-15** via `insert_driver_remove_line`. "Sabahoo" is ambiguous (Butter / Chocolate / Fruit Slice) → resolve to the Sabahoo VARIANT currently on the AMZ-1068 shelf via `v_live_shelf_stock`; if >1 variant present, pick the one matching exp 2026-06-15. (NB Sabahoo - Chocolate is a prior decommission target — a removal is consistent with that.)
- **OMDBB-1020-0P00-O1 (OMDBB 0809, dev 0809)** — date **2026-06-08**: **Refill Vitamin Well - Antioxidant 1 @ 2026-08-30** via `log_retroactive_refill_visit`.
- **ALJLT-1015-0200-O1 (ALJLT-01 0799, dev 0799 — ACTIVE cabinet; 1014 is Inactive)** — date **2026-06-09**, all via `log_retroactive_refill_visit` (Refill):
  - Hunter Ridge - Himalayan Pink Salt 2 @ 2027-02-03
  - Hunter - Sea Salt & Cider Vinegar 2 @ 2027-02-01
  - Hunter - Hot Chili 2 @ 2027-02-19 (resolve exact Hunter Hot Chili variant)
  - Dubai Popcorn Butter 1 @ 2027-02-01 **and** Butter 1 @ 2027-02-07 (two batches, keep separate expiries — do not merge)
  - Dubai Popcorn Salted 2 @ 2027-03-01

### B2 — Engine / packing bug to record (NOT a data fix)

- **OMDBB-1020** "1 pc VW Antioxidant is in packing but the pick-up qty does not show, so packed to recommended qty." → log ONE `action_tracker` row (type `bug`, machine OMDBB-1020) describing the packing-FE pickup-qty display gap on swap/refill rows. Do not change data. (Candidate Stax ticket; cross-ref BUG-tracker.)

### B3 — Driver recommendations → SIGNALS (driver_recommendations, NOT refills)

Write one rec row per line (resolve product via docs/refill-aliases.md; mixes = multi-variant even split flag, the engine resolves at run time). NONE are logged as refills.

- **AMZ-1029 (0745):** Kinder Bueno 5, Snickers 5, KitKat 5, Smart Gourmet Classic Humus 3.
- **ADDMIND-1007-0000-W0 (0791):** KitKat 6, Kinder Delice 5.
- **OMDBB-1020 (0809):** "need more McVities" → McVities Digestive Mini (Milk+Dark, even split), qty unspecified → flag `qty_unspecified`.
- **ALJLT-1015 (0799):** Barebells mix 15 (even split), KitKat 10, Kinder Delice 3, Ice Tea - Peach 6, Bounty 4.
- **WPP-1002-4300-O1 (0793):** Be-Kind Cluster mix 5 (even split), Oreo 3.
- **WAVEMAKER-1006-4100-O1 (0792):** KitKat 5, Mars 4, Snickers 3, McVities Dark 3, McVities Milk 3.
- **MINDSHARE-1009-4500-O1 (0807):** Kinder Delice 3, McVities Dark 4, McVities Milk 4, Kinder Bueno 3.
- **HUAWEI-2003-0000-B1 (0819):** KitKat 6, Kinder Delice 4, McVities Dark 4, McVities Milk 4, Oreo 3, Tamreem Date Ball mix 6 (Coconut+Sesame even split), Vitamin Well mix 8 (even split across VW variants), Mars 4.
- **MC-2004-0100-O1 (Mastercard 0815):** YoPRO mix 6 (even split).

> WPP McVities placement guardrail (memory): McVities Digestive Mini belongs on the Snack Bar shelf, not Chocolate Bar — carry into rec metadata where a shelf is implied.

---

## Resolution table (new shorthands this round)

- "Sabahoo" → resolve to on-shelf Sabahoo variant (Butter/Chocolate/Fruit Slice) via v_live_shelf_stock.
- "Himalayan pink salt" → **Hunter Ridge - Himalayan Pink Salt** (NOT Soul Pantry).
- "Hunter Sea salt Vinegar" → **Hunter - Sea Salt & Cider Vinegar**.
- "iced tea peach" → **Ice Tea - Peach**.
- "Eviron Wellness" → **Eviron - Wellness Drink**.
- "G&H Popped" → **G&H Popped Protein - Salt & Black Pepper**.
- "tamreem dates ball" → **Tamreem Date Ball** (Coconut + Sesame, even split).
- "well vitamin mix" / "yo Pro mix" / "barebells mix" / "be kind cluster mix" → multi-variant even split (FLOOR(qty/N) + remainder to oldest expiry).
- "delice" → Kinder Delice; "Bueno" → Kinder Bueno; "hummus" → Smart Gourmet - Classic Humus; "mcvities dark/milk" → McVities Digestive Mini Dark/Milk.

## Constraints (carry from PRD-017/018/019)

Cody before any canonical-writer/view/trigger change; verbatim bodies; service-role bypass pattern (`IF auth.uid() IS NOT NULL AND NOT role-ok THEN RAISE`); pod_inventory_audit_log operation lowercase + valid source; pod_inventory.status enum; warehouse_inventory.status manager-only; RPC-only writes to refill_dispatching/pod_refill_plan/refill_plan_output (+ allow-list, block_orphan_internal_transfer, tg_audit_refill_dispatching); `log_retroactive_refill_visit` = Refill/Add New only (source_origin warehouse | vox_at_venue), Removes via `insert_driver_remove_line`. Genuine catalog gaps → park + procurement, never guess. Past/invalid expiries already corrected by Simran in Part A — use the corrected dates. Verify every write in a rolled-back tx first; update RPC_REGISTRY.md + CHANGELOG.md + this PRD status. BUG-D reservation work (PRD-018) is NOT in scope.

## DONE criteria

- [x] Part A: 6 corrected lines logged on their original visit dates (AMZ-1029 ×3, NOOK ×2 products, Vox 0795 ×1, Vox 0797 ×1); A6 Hummus left parked; resolved action_tracker rows marked resolved; Mirdif note closed.
- [x] Part B1: OMDBB VW Antioxidant refill (08/06) + ALJLT-1015 Hunter+Dubai-Popcorn lines (09/06) logged; two-batch Dubai Popcorn Butter kept as separate expiries. **AMZ-1068 Sabahoo remove NOT re-logged** — already represented (see Execution status).
- [x] Part B2: OMDBB packing-qty bug row in action_tracker.
- [x] Part B3: all 9 machines' driver recs in driver_recommendations as signals (NOT refills); mixes flagged even-split; OMDBB McVities flagged qty_unspecified.
- [x] Registries + PRD status updated.

## Execution status — DONE 2026-06-10 (Supabase `eizcexopcuoycuosittm`)

All writes via existing canonical RPCs + one Cody-approved dedup fix. Verified in-DB.

- **Cody gate:** dedup fix to `log_retroactive_refill_visit` (add `expiry_date IS NOT DISTINCT FROM v_expiry` to the per-line dedup) — needed so the two same-qty/same-shelf Dubai Butter batches don't false-collapse. Migration `prd020_retro_log_dedup_include_expiry`. Cody ✅ (Articles 1, 4, 8, 12); body otherwise verbatim.
- **Part A (6 lines, 14 retro rows total incl. PRD-019 context):** AMZ-1029 05-Jun → Hunter S&V 1@2027-02-01 (A10), Dubai Salted 3@2027-02-17 (A11), VW Reload 2@2026-08-30 (A16). NOOK-1019 05-Jun A15 → Eviron 4@2027-04-29 + G&H Popped Protein S&BP 3@2026-08-26. Vox 0795 + Vox 0797 06-Jun `vox_at_venue` → VW Care 2@2026-09-06 each. All `rows_logged`, 0 dup-skips. `G&H Popped Protein - Salt & Black Pepper` (113f1d60) and `Hunter - Sea Salt & Cider Vinegar` (38638231) confirmed real catalog entries (not gaps).
- **Part B1:** OMDBB-1020 08-Jun VW Antioxidant 1@2026-08-30. ALJLT-1015-0200 (dev 0799 ACTIVE; 1014 Inactive) 09-Jun → Himalayan Pink Salt 2@2027-02-03, Hunter S&V 2@2027-02-01, Hunter Hot Chili 2@2027-02-19, **Dubai Butter 1@2027-02-01 AND 1@2027-02-07 (two separate rows, distinct expiries — verified)**, Dubai Salted 2@2027-03-01.
- **Sabahoo (B1) — NOT logged (conservation):** AMZ-1068 already has a `Remove` of qty **4** Sabahoo-Chocolate (exp 2026-06-15) dated 2026-06-08 — the full-batch decommission (batch held only 4 units, all removed via dispatch 07b065e4). Adding the PRD's "remove 1" would over-count (5 from 4). Per no-over-count discipline it was not re-logged; the driver's pull is already represented. Tracked via a new `action_tracker` task row for CS to confirm closure. Variant resolved unambiguously = Sabahoo - Chocolate.
- **Part B2:** one `action_tracker` `bug` row, machine OMDBB-1020 (packing-FE pickup-qty display gap). No data change.
- **Part B3:** 32 driver-rec signals across 9 machines via canonical `driver_propose_adjustment` (kind `needs_product`); 6 mixes written with `boonz_product_id` NULL + `EVEN_SPLIT` flag in note (OMDBB McVities, ALJLT Barebells, WPP Be-Kind Cluster, HUAWEI Tamreem, HUAWEI Vitamin Well, MC-2004 YoPRO); OMDBB McVities flagged `qty_unspecified`; McVities lines carry "Snack Bar shelf" guardrail note. NONE logged as refills.
- **action_tracker close-out:** VW Reload date-fix (daa25753) → done; NOOK qty (4036b8c1) → done; Mirdif note (2ca32383) → dismissed; AMZ-1029 A6 Hummus (3dbfd7ed) **left open** (product N/A, parked to procurement). NB only one date-fix tracker row existed (VW Reload); Hunter S&V / Dubai Salted corrections were inline PRD-019 notes, never separate tracker rows.
