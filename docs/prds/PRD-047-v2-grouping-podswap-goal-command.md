/goal PRD-047 v2: (1) fix the packing-page shelf GROUPING, then (2) rebuild Swap as a pod-level whole-shelf swap. MODE AUTO, no questions. Full spec: boonz-erp/docs/prds/PRD-047-packing-ux-shelf-grouped-swap.md (1a + 1b). Browser-verification gate is HARD. Do PHASE 1 then PHASE 2; close each.

PRE: git pull --rebase main; branch feat/prd-047-v2.

PHASE 1 - GROUPING FIX (FE only). Current grouped layout groups by PRODUCT and shows FEFO batches as rows = wrong. Fix:

- GROUPING KEY = SHELF (shelf_id). ONE card per shelf, header = shelf code + pod name (e.g. "A09 - Loacker"). All boonz SKUs on the shelf share that one card.
- ONE ROW PER SKU (boonz_product_id). A SKU spanning multiple FEFO batches = ONE row showing earliest-expiry; batch detail is secondary (expand/caption), never sibling rows.
- ONE shelf TOTAL = SUM(Pick Qty) across the shelf's SKUs. Remove per-product/per-batch subtotals.
- Verify example: A09 with Loacker-Napolitaner + Loacker-Vanille = ONE card, two rows, total 12 (NOT two cards each 6).

PHASE 2 - POD-LEVEL SWAP (backend + FE).
BACKEND (Dara design, Cody review, forward migration): new DEFINER `swap_shelf_pod(p_plan_date, p_machine_id, p_shelf_id, p_new_pod_product_id, p_reason)`, atomic in one tx:
a. REMOVE every current dispatch line on the shelf (all SKUs of the old pod) as action `Remove` at current qty.
b. TARGET = the shelf capacity (max_stock for that shelf).
c. SPREAD target across the NEW pod's active mapped SKUs using the SAME stitch v26 distribution (normalized split_pct over WH-available variants, largest-remainder, on-shelf tie-break, conservation). Reuse it as a SHARED SQL helper so swap and stitch never diverge; if not cleanly extractable, replicate exactly and note it.
d. WRITE one `Add New` line per SKU (title-case, source_kind='wh' machine primary warehouse, FEFO at pack). Inherit add_dispatch_row guards + audit. Grants authenticated/service_role. Cody Art 1/4/8/12.
FE: Swap dialog becomes pod-level: Remove = AUTO-FILLED read-only = the shelf's current pod (no sub-item picking); Add New = a POD-product picker (in-stock + size/lane compatible); NO qty field. Confirm calls swap_shelf_pod. One tap: select shelf -> pick new pod -> done.

HARD GATE - BROWSER VERIFICATION (before any deploy):

- Self-review vs the web-design-guidelines skill.
- 375px real browser (Claude-in-Chrome or playwright headed): no h-scroll, targets >=44px, axe wcag2a/2aa clean; save a screenshot.
- Functional: T1 multi-SKU shelf = one card + SKU rows + one total; T2 Pick edit updates shelf total; T5 collapse/expand; T8 Pick clamp + 0->Not Filled; T3 pod swap removes ALL old-pod lines + adds new pod spread at capacity; T3b add qty == capacity, split == stitch result; T4 atomicity (all-or-none); T9 confirm mixed states; T10 swap then confirm.
- Mutating tests (T3/T3b/T4/T10) run in BEGIN..ROLLBACK on a synthetic/non-dispatched shelf; never touch live dispatched/packed rows. STOP on any failure; do not deploy a failing result.

DEPLOY: when green, deploy to Vercel prod (boonz-erp.vercel.app). If the deploy cap is active, wait/Redeploy. Prod serves MAIN only; the push to main needs my explicit go-ahead - pause and ask only for that one push. Smoke-test prod: one card/shelf render + Swap dialog auto-filling the current pod.

HARD SAFETY: no picker/engine change; swaps_enabled stays false; engine_add_pod byte-identical; no live dispatched/packed rows modified; forward-only git, no destructive rewrite; preserve concurrent work via rebase --autostash. Backend limited to swap_shelf_pod (+ optional shared helper); stitch logic stays byte-equivalent if you extract the helper.

CLOSE: update PRD-047 (1a grouping fixed; 1b pod-swap shipped) with deploy commit + screenshot; append EXECUTION LOG. Summary: tests pass/fail, deploy URL, anything skipped.
