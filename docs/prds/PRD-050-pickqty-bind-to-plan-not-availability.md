# PRD-050 - Packing Pick Qty binds to the PLAN, not warehouse availability

**Status (2026-06-23):** ✅ Shipped to prod (5282f75, smoke green; built on branch `feat/prd-050-pickqty-plan-cap` `4ea8afa`). PRD-071 sweep 2026-07-02. FE-only; no backend/RPC/view/migration. `tsc` + `npm run build` green. Browser gate at 375px all green (T1-T8; axe 0; 0 controls <44px; no h-scroll). **Prod deploy pending the one main push.** See EXECUTION LOG.

## 0. Problem

On `/field/packing/<machine>` the per-SKU batch Pick Qty inputs (and "Total picked") were hard-clamped to **warehouse availability** (`batchAvailable = stock - committed`): `max={batchAvailable}`, `onChange = Math.min(batchAvailable, …)`, and `initBatchPickQtys` + its FEFO top-up only filled each batch's headroom. So when the **plan** (`recommended_qty = line.quantity`) exceeded in-stock, the Pick capped to stock and Total picked understated the backend quantity. The header (which reads `recommended_qty`) was already correct, so header and Total disagreed. Repro: VML-1004 A03 Popit Original Cola (plan 4, 1 batch stock 2, showed 2; backend filled 4 only after a manual edit).

## 1. The fix (FE only)

Applied to all four batch-input blocks in `src/app/(field)/field/packing/[machineId]/page.tsx` (the add/swap PACK inputs and the standard refill inputs, mix + single variant):

1. **Cap at the PLAN, not stock.** New helper `batchPlanCap(dispatchId, groupBatches, target, whId)` = `max(0, target - sum(other batches in the group))` where target = `recommended_qty` for a single-variant line, `v.packQty` for a mix variant. The line/variant TOTAL caps at the plan; an individual batch may exceed its own stock. Inputs use `max={batchCap}` and `Math.min(batchCap, …)`.
2. **Allow over-available.** Dropped the `disabled={… || batchAvailable === 0}` lock (now just `isReadOnly`). A pick above stock is allowed and flagged, never silently reduced.
3. **Oversubscribed cue (icon + text, never colour alone).** When `pickQty > batchAvailable`: amber input border + a `⚑ over` badge under the input.
4. **No silent shortfall in init.** After FEFO-filling each batch's available headroom, the remaining shortfall is placed on the **earliest-expiry** batch (flagged oversubscribed) so Total picked reaches `recommended_qty`.
5. `recommended_qty` (= `line.quantity`) and `filled_quantity` bindings are unchanged. No backend / view / RPC / migration change. swaps_enabled untouched.

Also (to pass the HARD 375px a11y gate): `aria-label` + `min-h-[44px]` + `focus-visible` on all batch inputs, and darkened pre-existing low-contrast muted/status text across the per-SKU view (expiry/age, shelf badges, "Recommended" labels, unit counts, "✓ Swap confirmed", the "Override & re-pack" button) so axe is wcag2a/2aa clean.

## 2. EXECUTION LOG (2026-06-23)

- **Logic test (pure functions, deterministic):** T1 plan 4 / 1 batch stock 2 -> Total 4, pick 4, oversub true, cap 4. T2 plan 2 / stock 5 -> Total 2, no oversub. T4 plan 6 / batches 2+3 (earlier+later expiry) -> FEFO fills 2+3, +1 shortfall on earliest -> 3+3 = 6, earliest oversub. Cap: line total never exceeds plan (batchCap = plan - others).
- **Browser (real Chromium, 375px, machine MINDSHARE-1009, read-only against prod):** drive an editable input to 9999 -> clamps to its plan cap (2), NOT unbounded; 0 -> accepted. `⚑ over` renders on 7 lines (e.g. A01 Ice Tea - Peach: In Stock 0u, Pick 2 = plan, Total 2, `⚑ over`). axe **0** wcag2a/wcag2aa violations; **0** controls < 44px; no horizontal scroll. Evidence `/tmp/prd050_final.png`.
- **T8 regression:** the grouped layout (`?layout=grouped`) still renders one card/shelf (8 cards, 8 shelf totals, 8 Swap-pod buttons); pod-swap dialog unaffected. Save/Finish unchanged.
- **T5:** the live VML-1004 A03 Popit line is now packed at filled 4 with WH stock recovered to 4, so it reads 4 (the plan-binding is demonstrated instead by the A01 Ice Tea render: stock 0 -> Pick 2 + the logic test).
- **No live dispatched/packed rows mutated** (verification was render-only + driving local React state). Forward-only git.

## 3. Note (out of scope)

The a11y darkening cleaned up pre-existing low-contrast text in the per-SKU view that predates this change (it is live in prod today); it was done only because the HARD gate requires an axe-clean 375px result.
