/goal PRD-050: fix the packing-page Pick Qty so it binds to the PLANNED quantity, not warehouse availability. FE-only, no backend. MODE AUTO, no questions. Full spec: boonz-erp/docs/prds/PRD-050-pickqty-bind-to-plan-not-availability.md. Browser-verification gate is HARD.

ROOT CAUSE (already verified in code): in src/app/(field)/field/packing/[machineId]/page.tsx the header reads `recommended_qty` (= line.quantity = the plan, correct) but the editable Pick Qty + "Total picked" read `batchPickQtys`, hard-clamped to batch availability: `batchAvailable = Math.max(0, b.stock - batchCommitted)`, the input is `max={batchAvailable}` with `onChange = Math.min(batchAvailable, ...)`, and `initBatchPickQtys` + its FEFO top-up only fill up to each batch's headroom. So when plan (e.g. 4) > in-stock (e.g. 2) the Pick caps at 2 and Total picked = 2, while the backend quantity is 4. Reproduced: VML-1004 A03 Popit Original Cola (plan 4, 1 batch stock 2, showed 2; backend filled 4 only after a manual edit).

PRE: git pull --rebase main; branch feat/prd-050-pickqty-plan-cap.

THE FIX (FE only, both the swap PACK inputs AND the standard refill batch inputs in this file):

1. Cap the Pick Qty at `recommended_qty` (the plan), NOT at `batchAvailable`. Replace `max={batchAvailable}` and the `Math.min(batchAvailable, ...)` clamp with a cap of the line's `recommended_qty` (line total caps at recommended_qty for multi-batch).
2. Allow a pick ABOVE available instead of blocking: when a pick exceeds availability, show the existing oversubscribed amber cue (icon + text, PRD-045) and let the value stand; never silently reduce it.
3. Fix `initBatchPickQtys` + the top-up loop so Total picked reaches `recommended_qty` even when total available stock is lower: FEFO-fill available headroom, then place the remaining shortfall on the earliest-expiry batch (flagged oversubscribed). No silent shortfall.
4. Do NOT change `recommended_qty` (= line.quantity) or `filled_quantity` bindings - they are correct. No backend / view / RPC / migration change.

HARD GATE - BROWSER VERIFICATION (before any deploy):

- Self-review vs the web-design-guidelines skill.
- Real browser (Claude-in-Chrome or playwright headed) at 375px: no h-scroll, targets >=44px, axe wcag2a/2aa clean; save a screenshot of the VML replay.
- Functional: T1 plan 4 / in-stock 2 -> Pick reaches 4, Total picked 4, oversubscribed amber, saves 4; T2 plan<=stock unchanged (no amber); T3 enter 0 -> Not Filled; T4 multi-batch plan 6 over 2+3 -> FEFO fills 2+3 then +1 on earliest expiry, Total 6; T5 VML-1004 A03 Popit Original Cola replay -> header AND Total both read 4 not 2; T6 save+reload -> 4 persists, no snap-back to 2; T7 a11y/375px; T8 regression: Save/Finish + grouped layout + swap unaffected.
- STOP and report on any failure; do not deploy a failing result. Read-only against prod data; do not mutate any live dispatched/packed rows (verify the rebind by reproducing the VML line's render, not by writing).

DEPLOY: when green, deploy to Vercel prod (boonz-erp.vercel.app). If the deploy cap is active, wait/Redeploy. Prod serves MAIN only; the push to main needs my explicit go-ahead - pause and ask only for that one push. Smoke-test prod: open the VML-1004 packing page, confirm the Popit Original Cola line lets you pick 4 with an oversubscribed cue.

HARD SAFETY: FE + git only; no backend/RPC/view/migration; picker/engines untouched; swaps_enabled stays false; no live dispatched/packed rows modified; forward-only git, no destructive rewrite; preserve concurrent work via rebase --autostash.

CLOSE: set PRD-050 to APPLIED (FE shipped) with the deploy commit + the 375px screenshot; append an EXECUTION LOG. Final summary: tests pass/fail, deploy URL, anything skipped.
