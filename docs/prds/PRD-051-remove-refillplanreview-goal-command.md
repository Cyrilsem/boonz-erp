/goal Remove the stale "Refill Plan / Approve All Machines" panel from the field app. FE-only, no backend. MODE AUTO, no questions.

WHAT + WHY (already verified): the panel is the `<RefillPlanReview />` component, rendered on the field landing page at src/app/(field)/field/page.tsx (import line 14, render ~line 726). It queries `refill_plan_output WHERE operator_status='pending'` with NO date filter and labels itself with the first row's plan_date, so it surfaces STALE un-approved rows (124 pending from 2026-06-13 + 55 from 2026-06-21 that were never approved/dispatched) and shows "Refill Plan — 13 June 2026" during today's refill. CS wants it gone from the flow. It is already removed from the snapshot tab; field/page.tsx is the only remaining render.

PRE: git pull --rebase main; branch feat/prd-051-remove-refillplanreview.

THE CHANGE (FE only):

1. In src/app/(field)/field/page.tsx: delete the `<RefillPlanReview />` render (the "Refill Plan Review (pending operator approvals)" block, ~line 725-726) and remove the now-unused `import { RefillPlanReview } from "@/components/RefillPlanReview"` (line 14).
2. Leave src/components/RefillPlanReview.tsx in the repo (do not delete the file; just stop rendering it) so nothing else breaks and it can be re-introduced later if needed.
3. tsc --noEmit + npm run build must be green (no unused-import / lint errors). Fix any fallout from the removed import only.
4. Do NOT touch refill_plan_output data, any RPC, view, or the packing page. This is purely removing one render + its import.

VERIFY (browser, before deploy):

- Self-review vs the web-design-guidelines skill (the field landing page should still render cleanly with the section gone, no empty gap/heading left behind).
- Real browser at 375px: open /field, confirm the "Refill Plan — <date>" / "Approve All Machines" panel is NO LONGER shown, and the page below it (Daily Refills section etc.) renders normally with no layout break or console error. Save a screenshot.
- Regression: /field/packing, Save/Finish, grouped layout, and swap are unaffected.
- STOP and report on any build error or layout break; do not deploy a broken result.

DEPLOY: when green, deploy to Vercel prod (boonz-erp.vercel.app). If the deploy cap is active, wait/Redeploy. Prod serves MAIN only; the push to main needs my explicit go-ahead - pause and ask only for that one push. Smoke-test prod: open /field, confirm the panel is gone.

HARD SAFETY: FE + git only; no backend/RPC/view/migration/data change; picker/engines untouched; swaps_enabled stays false; no live dispatched/packed rows modified; forward-only git, no destructive rewrite; preserve concurrent work via rebase --autostash.

NOTE (do NOT action in this goal - flag only): ~179 orphan `operator_status='pending'` rows in refill_plan_output (124 on 2026-06-13, 55 on 2026-06-21) are dead data that was the panel's source. Removing the panel hides them but does not clear them. Recommend a separate, reviewed cleanup later; do not delete/mutate them here.

CLOSE: print a short summary - file diff (2 lines removed), build result, deploy commit + URL, screenshot ref.
