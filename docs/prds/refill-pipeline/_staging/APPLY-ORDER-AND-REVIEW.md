# PRD-REFILL-V2 — apply order, review flags, items 4 & 7

Status: ALL STAGED. Nothing applied to prod. Each engine writer needs CS green light.
Branch: `feat/refill-v2-staged-engines`. Dry-run anchor: plan_date 2026-06-09.

## Apply order (dependency-correct)

1. **Item 3** `20260608121000_refillv2_resolve_driver_intent_translator.sql` — read-only INVOKER, no dependents broken. Apply first (item 6 calls it; applying stitch v19 before this would fail).
2. **Item 1** `20260608120000_refillv2_engine_add_pod_v15_fill_to_cap.sql` — writes the dead tags item 2 consumes. Apply before item 2.
3. **Item 2** `20260608122000_refillv2_engine_swap_pod_v10_narrow_trigger.sql` — consumes item 1's tags.
4. **Item 5** `20260608123000_refillv2_pick_machines_v8_p1_restock.sql` — independent; any time.
5. **Item 6** `20260608124000_refillv2_stitch_driver_overlay_shelfguard.sql` — requires item 3 live.

Recommended sequence: **3 → 1 → 2 → 5 → 6**. After each apply, re-run the relevant dry-run on a fresh plan_date and confirm the proof numbers, then run `engine_finalize_pod` only when satisfied.

## Per-item review flags (decide at sign-off)

- **Item 1**: (a) pod_swaps.reason reuse 'dead'/'rotate_out' + provenance — CONFIRMED (no constraint ALTER). (b) WIND DOWN kept as drain (qty 0, no swap tag), not filled — confirm or flip.
- **Item 2 (v10)**: (a) `qty_in` for a resolved swap-in uses `GREATEST(wh_stock_units, 4)` (find_substitutes has no "suggested fill" column) — confirm basis, or switch to half-shelf-max like Pass 1. (b) Pass 1 strategic-intent swaps KEPT — remove only if you want a pure dead-tag+driver-rec engine. (c) driver_recommendations open-status literal assumed `'open'` (table empty today; forward-support no-op). (d) M2W return stays downstream at stitch — CONFIRMED.
- **Item 6 (v19)**: (a) overlay = driver SKU first-claim, remainder by mix_weight — CONFIRMED, invariant `sum(variant)=pod_qty` validated (4/2/4=10 with a pin). (b) shelf-code guard is defensive only (all 2615 live codes already canonical A01..E16); the WEIMI ELSE branch never fires today.

## Item 4 — expiry daily rule (lightweight; NO separate engine)

Per PRD: "slot with expired/at-risk units → if product performs, step 1 refills it; if not, tag it for step 2. No strategic batch engine." This is satisfied by the existing pieces, no new engine_expiry_pod:

1. **Performer with expiry**: stays non-dead in v15 → fills to capacity; the physical expired units are removed at dispatch by the FEFO walk (expiration_date ASC NULLS LAST). Net: re-stocked, oldest-out.
2. **Non-performer with expiry**: v15's dead test (velocity_30d=0 or dead stance) already catches it → qty 0 + pod_swaps tag → item 2 swaps it. Expiry and non-performance coincide here.
3. **Selection**: `get_machine_health` / `v_machine_health_signals` already expose `expired_skus_now/3d/7d/30d`; picker v8 keeps them as P2_MAINTAIN drivers, so expiring machines get visited.

Optional thin augmentation (only if CS wants expiry to _force_ a tag even when velocity_30d>0): add a per-slot `at_risk_expiry` boolean to v15's `flagged` CTE (from pod_inventory expiration within N days) and OR it into the dead test for non-performers only. Not built by default — the emergent behavior above already covers the PRD rule. Flag if you want it.

## Item 7 — 8pm cron (CONFIRMED correct, no change required now)

`build_draft_for_confirmed` (job 13, `0 16 * * *` = 20:00 Dubai) chains:
`confirm_machines_to_visit → engine_add_pod → engine_swap_pod → engine_finalize_pod` and **STOPS at the finalized draft**. Verified: **no** `stitch_pod_to_boonz`, **no** `approve_refill_plan`, **no** `approve_pod_refill_plan` — no auto-approve, no auto-stitch. Operator approves on the Vercel page → backend stitches + dispatches with no Cowork. (Picker runs separately, job 14, 6am Dubai.)

Only forward change, and only if CS opts into the optional item-4 augmentation: insert that expiry step between `engine_add_pod` and `engine_swap_pod`. With the emergent design, the chain needs no edit.

## Verify (when applying)

SQL migrations — no `tsc`/build surface. Per writer: apply, then `SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname='<fn>'` to confirm the single signature was replaced (no overload created), and re-run the item's dry-run query (in the CHANGELOG entry) to reconfirm the AC numbers on live before finalizing.
