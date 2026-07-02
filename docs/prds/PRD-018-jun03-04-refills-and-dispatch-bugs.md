# PRD-018 — 03-04 Jun refill logs + dispatch-side bug fixes

**Owner:** Claude Code · **Created:** 2026-06-04 · Supabase `eizcexopcuoycuosittm`
**Format:** engineering build-spec (same discipline as PRD-016/017). Carry ALL §6 constraints.
Two parts: **Part 1** = log the placements (data, RPC-only). **Part 2** = fix 3 new dispatch-side bugs with edge cases.

## Machine map (resolved)

NISSAN-0804-0000-L0 · MC-2004-0100-O1 · OMDCW-1021-0100-W0 · NOVO-1023-0000-W0 ·
AMZ-1068-2401-O1 (device **0705**) · AMZ-1057-2403-O1 (0716) · AMZ-1038-3001-O1 (0735) · VML-1003-0400-O1 (4F, 0810).
Already logged (01-02 Jun, PRD-017 §0) — do NOT redo.

## Resolution rules (deterministic)

- Resolve each shorthand to `boonz_products.product_id`; confirm `product_mapping` (machine-specific else `is_global_default`) per machine. Use the alias conventions in `docs/refill-aliases.md`.
- Pod is WEIMI-fed → **log-first**: create the refill log; write pod only for genuine discrepancies. WH not debited (placements logged only).
- Multi-batch same product+expiry on one machine+date: combine to one line (qty summed), earliest expiry, batches noted in comment (dedup guard keys on machine+date+boonz+qty+action+shelf).
- Transfers: tag `source_origin` per the source; M2M between machines uses the transfer convention (comment `[TRANSFER from <machine>]`, source not 'warehouse').
- Genuine catalog gaps → PARK + procurement action_tracker, do not guess: **"Pepsi Peach"** (no catalog match — confirm = Ice Tea Peach? or a Pepsi variant), **"Pepsi Diet & Pepsi Regular 6"** (split unspecified — log as Pepsi Regular 3 + Pepsi Black 3 per the standing "diet=Black" rule unless CS says otherwise).

---

## PART 1 — Placements to log (`log_retroactive_refill_visit`, action 'Refill'/'Add New')

### 04 Jun (TODAY) — manual refill, no system plan. PRIMARY ASK.

- **NISSAN-0804 (warehouse):** YoPRO Choc 4 (01/09/26), YoPRO Vanilla 3 (27/08/26)+1 (19/08/26), YoPRO Strawberry 2 (21/08/26)+1 (31/08/26); Krambals Green Olives 2 (13/11/26), Tomato 2 (14/09/26), Forest Mushroom 2 (16/01/27); McVities Nibbles Milk 3 (06/09/26), Dark 3 (09/08+29/08+03/11/26), Double 3 (13/08/26), Choco Caramel 1 (12/08/26); Barebells Caramel Cashew 7 (17/11/26), Hazelnut Nougat 7 (22/12/26), Salty Peanut 3 (26/11/26); Activia Honey&Oats (16/07/26), Activia Strawberry (16/07/26) [qty as stated]; Sunbites Olives 1 (11/09/26).
- **MC-2004 (warehouse):** Mars 5 (01/12/26), Bounty 5 (04/12/26), Popit Cola 4 (17/10/26), Be-kind Bar Peanut Butter 5 (10/02/27), Be-kind Bar Almond & Sea Salt 1 (06/01/27), YoPRO Strawberry 2 (31/08/26), YoPRO Choc 2 (01/09/26), Soul Pantry Cheese&Garlic 2 (27/12/26), Soul Pantry Smokey Chipotle 2 (01/06/27), Soul Pantry Himalayan Pink 1 (27/12/26), Al Ain Water 4 (10/04/27), Popcorn Butter 1 (01/02/26 — PAST → skip/confirm), Popcorn Salt 1 (01/02/26 — PAST → skip/confirm).
- **OMDCW-1021 (warehouse):** Kinder Delice 5 (17/07/26), Oreo 5 (05/11/26), McVities Dark 4 (11/12/26), McVities Milk 3 (29/10/26), Kinder Bueno 5 (19/11/26), Mars 6 (01/12/26), Twix 4 (27/02/27), Nutella Biscuit T12 4 (24/11/26), Pepsi Peach 5 [GAP→park], Pepsi Black 3 (15/11/26), Pepsi Regular 3 (25/02/27), Ice Tea Peach 5 (05/05/27).
- **NOVO-1023 (warehouse):** Smart Gourmet Classic 5 (25/01/27); Barebells Caramel Cashew 8 (17/11/26), Hazelnut Nougat 6 (22/12/26); Benlian Pizza 1 (30/10/26), Sour Cream 1 (14/10/26), Sea Salted 2 (13/10/26); Activia Honey&Oats 2 + Strawberry 2 (16/07/26) [expiry-replace = set/refresh, not add — use adjust_pod_inventory if correcting expiry]; Coca-Cola Zero 4 (03/11/26), Pepsi Black 4 (15/11/26). **Swap:** A11 Barkthins REMOVED → replaced with Be-kind Bar (log Remove Barkthins + Add New Be-kind Bar variant; confirm variant).

### 03 Jun — uncovered prior run.

- **AMZ-1068:** Al Ain Water 14 (10/04/27), Vitamin Well Reload 1 (23/08/26), Red Bull Regular 3 (04/11/27).
- **AMZ-1057:** Pepsi Black 3 (29/10/26), Sunbites Cheese 2 (21/09/26), Krambals Green Olives 1 (13/11/26) **[TRANSFER from AMZ-1068 / device 0705]**.
- **AMZ-1038:** Organic Rice unavailable → shelf replaced with Snack Bar/KitKat (log the KitKat/Snack Bar Add + note Organic Rice shelf retired).
- **VML-1003-0400 (4F):** adds — Coca Cola Zero 23 (combine w/ remaining 5 = note), Popcorn Salt 1, Nibbles Milk 1, Popit Orange 4, Popit Cola 5, Popit Lemon&Lime 5. **Removed:** Evian Regular 10 → replaced with Poppit Mix (log Remove Evian + Add Popit mix).
- **OMDCW-1021:** Al Ain Water 19 (10/04/27).

### Driver recs → action_tracker + driver_feedback (next-visit)

- AMZ-1038 (03/06): more Oreo, more McVities.
- OMDCW-1021 (03/06): Delice 5, Oreo 5, McVities Dark 4, McVities Milk 3, Bueno 5, Mars 6, Twix 4, Nutella 4, VW Peach 5, Pepsi Diet&Regular 6.

---

## PART 2 — New dispatch-side bugs (RCA + fix, edge cases). Each own migration, Cody first.

### BUG-C — packed items not appearing in dispatch list

**Symptom (03/06):** AMZ-1068 VW Reload; AMZ-1057 Pepsi Black + Sunbites Cheese; VML entire refill; OMDCW Al Ain Water — confirmed in packing but absent from the dispatch list.
**RCA step:** for each, check whether a `refill_plan_output` row existed (approved) but no matching `refill_dispatching` row (the Hard-Rule-8 coverage gap), or whether packing acted on a draft never pushed via `push_plan_to_dispatch`. Identify where the approve→dispatch bridge drops the row.
**Fix:** ensure every approved/confirmed plan row bridges to `refill_dispatching` (autobridge trigger + `push_plan_to_dispatch` v3). Edge cases (ALL): (1) manually-added/edited rows must bridge too; (2) multi-variant rows each bridge; (3) source_origin/from_machine_id propagate; (4) a machine confirmed AFTER other machines in the same session still bridges (no cross-machine state wipe); (5) idempotent — re-running creates no duplicates; (6) the post-bridge coverage query (approved EXCEPT dispatched) returns empty.

### BUG-D — inventory not deducting mid-refill / pickup qty → 0

**Symptom (03/06):** Al Ain Water packed on AMZ-1068 (14) then OMDCW (19) from shared WH_CENTRAL; after confirming earlier machines the pickup qty went to 0 on later ones though stock was physically present, and the inventory display still showed 37 (stale, not deducting).
**RCA step:** trace WH availability across sequential same-session confirmations for a shared-WH product. Determine if availability (PRD-017 §1) over-decrements (double-counting reservations/in-flight dispatches) to 0, AND why the inventory count display doesn't reflect deductions (stale read vs actual warehouse_stock).
**Fix + edge cases:** availability must decrement exactly once per committed dispatch; reservations and committed decrements must not double-count; a product split across multiple machines in one session shows each machine its fair remaining (never spurious 0 while stock>0); the count display reads live `warehouse_stock` (not a cached/stale value); never count `consumer_stock`; FEFO. Reconcile the 37-vs-actual for Al Ain Water as part of verification.

### BUG-E — variant mismatch: packed ≠ dispatch (Red Bull Regular → Diet)

**Symptom (03/06):** AMZ-1068 packed Red Bull Regular but dispatch list shows Red Bull Diet.
**RCA step:** multi-variant pod ("Red Bull" → Regular/Diet) — the dispatch product resolution (push_plan_to_dispatch / dispatch product mapping) defaulted to the wrong variant vs what was packed. Sibling of the PRD-016 returns variant bug, on the OUTBOUND side.
**Fix + edge cases:** dispatch must carry the SAME boonz variant that was packed/planned (no silent default flip); multi-variant pod resolves to the planned variant, not is_global_default; if ambiguous, surface (do not guess); verify packed boonz_product_id == dispatch boonz_product_id for every multi-variant row.

---

## Constraints (carry from PRD-016/017, mandatory)

Cody before every canonical-writer/view/trigger change; verbatim body reproduction; service-role bypass pattern; pod_inventory_audit_log operation∈(insert,update,delete)+source∈(seed,sale,refill,manual_edit,weimi_sync,correction,cleanup); pod_inventory.status∈(Active,Inactive,Expired,Removed,Removed/Expired); warehouse_inventory.status manager-only (propose-then-confirm); RPC-only writes to refill_dispatching/pod_refill_plan/refill_plan_output (+ enforce_canonical_dispatch_write allow-list); verify in rolled-back tx; smoke field/packing+field/pickup; update RPC_REGISTRY/CHANGELOG/PRD status. log_retroactive_refill_visit only does Refill/Add New — Removes use insert_driver_remove_line.

## DONE CRITERIA

- [x] Part 1: all 03/06 + 04/06 placements logged (4 manual machines + 5 prior-run machines); transfers/swaps tagged; driver recs queued; gaps parked. **DONE 2026-06-04.** 58 placement lines + 4 removes via `log_retroactive_refill_visit`/`insert_driver_remove_line`; 13 `driver_feedback` recs; AMZ-1057 Krambals tagged `[TRANSFER from AMZ-1068/0705]`; AMZ-1038 + NOVO + VML swaps logged. Resolution corrections: Al Ain→"Al Ain Water - Regular", OMDCW McVities→Mini variants, "Pepsi Peach"→dropped as Ice Tea Peach dup (CS). **3 parked in action_tracker (need CS):** NISSAN Activia qty; NOVO Be-kind Bar Dark add (no product_mapping at NOVO); NOVO Activia expiry-refresh (idx_pod_inv_active_shelf blocks dual-expiry / destructive overwrite).
- [x] **BUG-C** — RCA recorded (silent `EXCEPTION WHEN OTHERS` swallow + whole-machine abort), fix applied (`push_plan_to_dispatch` v6_resilient_bridge + non-silent `trg_fire_dispatch_on_approval`) + Cody ✅, all edge cases verified in rolled-back tx (good bridges, transfer skips, poison fails in isolation, idempotent, failures surfaced). Migrations `prd018_bugc_resilient_dispatch_bridge` + `prd018_bugc_bridge_severity_fix`.
- [~] **BUG-D — HELD for Dara (RCA done).** Root cause: `pack_dispatch_line` moves warehouse_stock→consumer_stock AND stamps `reserved_for_machine_id` on the WHOLE batch when packing only part, so `v_dispatch_availability` + `pick_wh_batch_for_machine` hide the shared batch's remaining warehouse_stock from other machines → spurious 0 while stock>0 (Al Ain). The view-only fix was **Cody-blocked** (would desync display from the pick path). Correct fix = reservation-semantics change on canonical writer `pack_dispatch_line` (stop earmarking the un-consumed remainder) + view + pick helper together → Dara, then Cody re-review. Display "stale 37" = FE summing warehouse+consumer → Stax. Not applied.
- [x] **BUG-E — backend guard DONE (FE → Stax).** Reframed: multi-`is_global_default`+`split_pct` is the fleet-wide mix design (NOT a Red Bull anomaly). Backend fix = guardrail-3 `flag_multivariant_pack_without_variant_confirmation()` BEFORE UPDATE trigger (outbound sibling of PRD-016 guardrail 2), WARN to `monitoring_alerts` when a multi-variant pod is packed without a `variant_action_log` correction; counts global-default mappings (closes guardrail 2's global-pod blind spot). Cody ✅, verified in rolled-back tx. Migrations `prd018_buge_guardrail3_pack_variant` + `_message_fix`. **Held:** Red Bull single-default is a product decision (no machine would get Diet) — awaiting CS re-confirm.
- [x] Registries + PRD status updated (BUG-C ✅, BUG-E ✅, BUG-D held); packing/pickup unaffected (backend-only, guard is WARN — pack still succeeds, verified; no FE touched).

---

## Stax FE follow-ups (handed off 2026-06-05)

- **BUG-C FE:** `RefillPlanningTab` should surface `push_plan_to_dispatch` `status='partial'` + `lines_failed`/`lines_skipped_internal_transfer` (don't treat non-`ok` as a hard error). Watch `monitoring_alerts.source IN ('dispatch_bridge_failure','dispatch_bridge_nonok','dispatch_bridge_exception')`.
- **BUG-D FE:** `field/pickup` + Stock Snapshot inventory count must read live `warehouse_stock` only, **never** `warehouse_stock + consumer_stock` (the "stale 37"). Blocked on the Dara reservation-semantics fix for the availability calc.
- **BUG-E FE:** `field/packing/[machineId]` must let the packer pick the actual physical variant for a multi-variant pod and call `record_variant_correction(p_action_type='dispatch_substitution', p_planned_variant_id, p_new_variant_id, p_qty, ...)` so the dispatch row carries the packed variant; `DailyDispatchingTab` then shows the corrected variant. This clears the guardrail-3 warning.

## Dara hand-off (2026-06-05)

- **BUG-D reservation semantics:** `pack_dispatch_line` should not hold the un-consumed remainder of a batch hostage to the first machine. Proposal: when `warehouse_stock` remains >0 after a pick, do NOT set (or clear) `reserved_for_machine_id` on that row, so the remainder stays shareable; then `v_dispatch_availability` (drop the reserved exclusion) and `pick_wh_batch_for_machine` agree. Decrement-once invariant preserved (warehouse_stock already moved to consumer_stock). Needs Dara design + Cody re-review of the writer.
