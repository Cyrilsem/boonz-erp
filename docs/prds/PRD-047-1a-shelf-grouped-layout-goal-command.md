/goal Rebuild the Boonz packing page /field/packing/<machine> into the shelf-grouped compact layout (PRD-047 section 1a), browser-verify it, then deploy to prod. MODE AUTO, no questions to me. PRD-047 is decision-complete at boonz-erp/docs/prds/PRD-047-packing-ux-shelf-grouped-swap.md. The browser-verification gate below is HARD: do not deploy without it.

CONTEXT (already live in prod, build ON these, do not redo): swap_dispatch_shelf RPC; FE Swap dialog (commit c7ac999); PRD-044 Save/Finish two-button; PRD-045 available_qty + oversubscribed badge (deploy 37ce14d). The page today is per-SKU panels; this goal converts it to shelf-grouped.

PRE: git pull --rebase on main; confirm c7ac999 and 37ce14d are present; create branch feat/prd-047-1a-shelf-grouped.

BUILD (PRD-047 1a + 1c):

- One CARD per shelf (e.g. "A05 - Activia Mix & Go"). Inside, a compact table, one row per SKU: Product | Expired | Req Qty | Pick Qty (editable) | In Stock.
- ONE shelf TOTAL row = SUM(Pick Qty); it is the only total shown.
- Reuse the EXISTING pieces inside the grouped view: Save/Finish (PRD-044), available_qty + oversubscribed badge (PRD-045), Swap button -> swap_dispatch_shelf at shelf level.
- Best practices (mandatory): mobile-first 375-414px with no horizontal scroll; touch targets >=44px; one primary action per shelf with Skip/Swap subordinate; status carries icon+text, never color alone; WCAG AA contrast/focus-visible/labels; progressive disclosure (collapse resolved shelves to a one-line summary, expand on tap); Pick Qty clamps [0..available], 0 routes to Not Filled; no dead ends (out-of-stock rows offer Swap / Not Filled inline).
- SAFETY ROUTE: ship behind a route/flag (e.g. ?layout=grouped or a feature flag) so a failing build never bricks the live per-SKU field tool.

HARD GATE - BROWSER VERIFICATION (do this before any deploy):

- Self-review against the web-design-guidelines skill.
- Open the page in a REAL browser (Claude-in-Chrome MCP or playwright headed) at 375px. T6: no horizontal scroll, targets >=44px. T7: axe/lighthouse a11y clean (contrast >=4.5:1, focus-visible, labels, status not color-only). Save a 375px screenshot as evidence.
- Functional: T1 multi-SKU shelf = one card + sub-rows + one total; T2 sub-row Pick Qty edit updates the shelf total live; T5 resolved shelf collapses/expands; T8 Pick Qty clamp + 0->Not Filled; T3/T4 Swap = atomic Remove + Add New; T9 confirm with mixed packed/partial/skip/not_filled; T10 swap then confirm.
- If ANY of T1/T2/T5-T10 fail, STOP and report; do not deploy a failing a11y/375px result.

DEPLOY: once all tests pass, deploy to Vercel prod (boonz-erp.vercel.app). If the free-tier deploy cap is still active, wait for reset or have me Redeploy from the Vercel dashboard. Smoke-test on prod: open a real packing page, confirm shelf-grouped render + a swap + Save/Finish.

HARD SAFETY: FE + git only; no backend RPC/view/migration change; picker and engines untouched; swaps_enabled stays false; do not modify any live dispatched/packed rows; forward-only git, no destructive history rewrite; preserve concurrent-session work via rebase --autostash.

CLOSE: set PRD-047 1a to "APPLIED (FE shipped)" with the deploy commit + the 375px screenshot reference; append to its EXECUTION LOG. Print a final summary: tests pass/fail, deploy URL, anything skipped.
