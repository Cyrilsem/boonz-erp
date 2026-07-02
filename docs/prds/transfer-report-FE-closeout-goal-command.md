/goal FE close-out for the "Stock Transfer Workflow & System Glitches" report: wire the already-built backend into the field app, browser-verify, deploy. MODE AUTO, run to green, NO pauses. Real-browser verify each at 375px (Playwright/Chrome: no h-scroll, targets >=44px, axe wcag2a/2aa clean, screenshot each), then push each branch to main; Vercel auto-deploys.

PRE: git pull --rebase main. Confirm backend is LIVE before wiring: stitch v28 conservation (PRD-053-A applied), pack_outcome 'packed_transferred' + confirm_packed_transferred writer (PRD-056 backend), wh_approve_remove_receipt_multivariant per-expiry write (PRD-053-B). Branch per piece.

1. PRD-050 (4->2 bug). File src/app/(field)/field/packing/[machineId]/page.tsx. Cap Pick Qty at recommended_qty (the plan), NOT batchAvailable; over-available shows the PRD-045 oversubscribed amber (icon+text); initBatchPickQtys + top-up reach recommended_qty (FEFO fill, remainder on earliest-expiry, flagged). Tests: plan4/stock2 -> Pick 4 + amber + saves 4; save+reload persists 4; multi-batch plan6 over 2+3 -> 6; enter 0 -> Not Filled; a11y. Smoke VML-1004 A03 Popit = 4.

2. PRD-053-B (multi-expiry split FE; the "Ice Tea does not work" surface). Backend ready (per-expiry breakdown RPC + multivariant receive writes pod_inventory per date). Wire the per-expiry split UI on (a) the dispatching/packing line and (b) the WH returns-approval panel: add rows per expiry, TOTAL locked to plan; on approve each batch lands in pod_inventory with its own date. Tests: Ice Tea 13 -> split 6+7, total locked; approve -> two pod_inventory batches with dates; an over-total edit is blocked.

3. PRD-056 FE (transfer-aware packing). Backend ready (packed_transferred + confirm_packed_transferred). For any is_m2m source row, or a row tagged "Transfer from <machine>", the ONLY confirm option is Packed & Transferred (hide Skip/Not Filled); confirm calls confirm_packed_transferred (lands the unit in the dest machine pod_inventory). The M2M dest leg renders a "Transfer from <source>" tag + one-tap confirm. Add an expiry field on a transferred add (reuse #2's split). Surface the Not-Filled -> transfer linked state. Tests: transfer row shows ONLY Packed&Transferred; confirm lands in dest pod_inventory; dest shows Transfer-from + one tap; a transferred add captures expiry; a Not-Filled+transfer pair shows linked.

GREEN GATE (no stop): per piece - tsc --noEmit + next build clean; real-browser 375px a11y pass + screenshot; the functional tests above. Any failure -> fix and re-run; never stop on a fail.

DEPLOY: push each green branch to main; Vercel auto-deploys prod (boonz-erp.vercel.app); if the deploy cap is hit, wait/Redeploy. Smoke each on prod. Also ensure the PRD-053-A + PRD-056-backend migration branches are on main (prod-sync) if not already.

CLOSE: one final per-item verdict table vs the team doc (every item green), commits, deploy URL, 375px screenshots.

SAFETY: FE + git only for pieces 1/2/3; no backend logic change (backend already built/applied); engine_add_pod/engine_swap_pod untouched; swaps_enabled false; forward-only git; no history rewrite.
