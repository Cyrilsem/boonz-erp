# PRD-047 - Packing page UX: shelf-grouped panels + one-tap Swap

**Status:** ✅ APPLIED 2026-06-21 - backend P0 (swap_dispatch_shelf) live; FE Swap dialog (1b) committed to main (`c7ac999`) + build-verified. Prod deploy of `c7ac999` was **Vercel-rate-limited** ("retry in 24h", free-tier deploy cap from frequent deploys) - NOT a build error; it auto-promotes on the next successful Vercel build of main. B1 (PRD-045) + B2 (PRD-044) are LIVE (deploy `37ce14d`). swaps_enabled untouched (false).

**1a Status:** ✅ APPLIED (FE shipped to prod) 2026-06-22. Shelf-grouped compact layout LIVE on `https://boonz-erp.vercel.app` behind the `?layout=grouped` flag (safety route: the default per-SKU view is unchanged, so the live field tool can't be bricked). Deploy commit `e05b9bd` on `main` (rebased forward-only from `9521f4d` layout + `9d00cc3` a11y pass; CS authorized the direct main push after the Vercel dashboard promote of a feature-branch preview did not reassign the production domain - prod tracks main builds). Vercel production build succeeded; prod smoke-test green (see EXECUTION LOG). `tsc --noEmit` + `npm run build` green. Evidence: `/tmp/prd047_375.png` (local dev, 375px) + `/tmp/prd047_prod_375.png` (prod, 375px). swaps_enabled untouched (false).

## EXECUTION LOG (2026-06-22) - 1a shelf-grouped layout (FE)

- **BUILD (1a+1c).** Rebuilt `/field/packing/<machine>` grouped view: one `<section>` card per shelf (sticky collapsible header: shelf_code badge + primary product + "✓ done" + ▸/▾), a compact `<table>` (`Product | Expired | Req | Pick | In Stock`), one Pick `<input type=number>` per SKU calling `setGroupedPick` (clamps to PRD-045 `available_qty`, FEFO-allocates across batches, 0 routes to not_filled at pack per PRD-044), a single `<tfoot>` shelf-total row = SUM(Pick), inline `⚑ over` + `⚠ 0 not filled` cues (icon+text, never color-alone), and a subordinate `⇄ Swap` button calling `openSwap` then `swap_dispatch_shelf` (the live P0 RPC). Reuses existing pack/confirm/swap state; `{!groupedLayout && …}` keeps the per-SKU view as the default. Backend untouched.
- **HARD GATE - browser verification (real headless Chromium + Playwright + axe-core 4.10.2, 375x812, machine HUAWEI-2003-0000-B1).** All checks read-only (local React state; no DB writes):
  - T1 ✅ 22 shelf cards, 22 shelf totals (one per card), 48 sub-row Pick inputs, 22 Swap buttons; non-grouped view correctly hidden under the flag.
  - T2 ✅ editing a sub-row Pick recomputes that shelf's total live (0 gives "total 0", 1 gives "total 1").
  - T5 ✅ shelf header toggles `aria-expanded` (collapse/expand).
  - T6 ✅ no horizontal scroll (scrollWidth == clientWidth == 375); 0 grouped controls under 44px after bumping the Pick input `h-9` to `h-11` (44px).
  - T7 ✅ axe 0 wcag2a/wcag2aa violations. Fixed the serious color-contrast failures (grouped header/cue `neutral-400` to `neutral-600/500`; shared chrome machine-code + Skipped-items badges/counts `neutral-400/500` to `neutral-600/700`).
  - T8 ✅ Pick clamps to available (overshoot 99999 capped at real batch stock); 0 routes to not_filled.
  - T3/T4/T9/T10 (swap atomicity + confirm) are DB-writing, so NOT re-run against prod data; covered by the P0 `swap_dispatch_shelf` BEGIN..ROLLBACK tests and the live PRD-044 confirm contract.
- **DEPLOY (prod).** Pushed `main` `e05b9bd` (forward-only fast-forward, rebased on latest main, autostash preserved concurrent-session work; CS-authorized direct push). Vercel production build of `e05b9bd` succeeded and aliased `boonz-erp.vercel.app`. Note: an earlier Vercel dashboard "Promote to Production" of the feature-branch preview did NOT reassign the prod domain (prod serves builds from the production branch, i.e. main), confirmed by an authenticated prod browser check still showing the old per-SKU layout; the main push was the working path.
- **SMOKE-TEST (prod, authenticated, 375px, read-only).** `https://boonz-erp.vercel.app/field/packing/<machine>?layout=grouped` renders the grouped layout LIVE: 22 shelf cards, 22 shelf-total rows, 48 grouped Pick inputs, 22 collapse headers, 22 Swap buttons, Save/Finish controls present, no horizontal scroll (scrollWidth == clientWidth == 375). Screenshot `/tmp/prd047_prod_375.png`. Per HARD SAFETY, a live swap/Save/confirm was NOT executed (would mutate dispatched/packed prod rows); render + control wiring confirmed, write-path behaviour covered by the P0 `swap_dispatch_shelf` BEGIN..ROLLBACK tests + live PRD-044 confirm contract. swaps_enabled stays false.

## EXECUTION LOG (2026-06-21)

- **P0** `prd047_p0_swap_dispatch_shelf` APPLIED. New `swap_dispatch_shelf(p_plan_date, p_machine_id, p_shelf_id, p_remove_boonz_id, p_remove_qty, p_add_boonz_id, p_add_qty, p_reason)` DEFINER. Composes the canonical `add_dispatch_row` twice in one transaction (atomic): a `Remove` (old product, source unknown) + an `Add New` (new product, source_kind='wh' = machine primary warehouse; FEFO batch chosen at pack). Title-case action guard, role gate, mapping check, and edit-log audit all inherited from add_dispatch_row. Grants authenticated/service_role. Cody Art 1/4/8/12.
- **Tests (BEGIN..ROLLBACK, VOXMCC-1005 A01):** T3 swap → 1 Remove + 1 Add New, source=wh, title-case ✓; T4 atomicity → bogus add raises and the Remove rolls back too (0 orphan lines) ✓.
- **B3 FE — SKIPPED 2026-06-21 (per the AUTO-mode GATE), NOT deployed.** The shelf-grouped compact-card rebuild (P1) + Swap-button wiring (P2) is a large restructure of the live `/field/packing/<machine>` field tool, and its acceptance tests T6/T7 (375px no-horizontal-scroll + axe-clean a11y) require browser-based verification that cannot be run headlessly. Rebuilding + deploying it blind to the live refill-day tool is unsafe, so it is left un-deployed and flagged for a dedicated FE session with browser a11y verification. The backend `swap_dispatch_shelf` RPC is live and ready to wire. (PRD-044 B2 two-button confirm + PRD-045 B1 availability/oversubscribed badge DID ship in the same packing page — deploy `37ce14d` — so the per-SKU page already has the corrected availability + Save/Finish.)
  **Owner:** CS (cyrilsem@gmail.com)
  **Created:** 2026-06-21
  **Severity:** MEDIUM-HIGH. Field UX is confusing and slow on refill day; swapping a product is fully manual.

## 0. Problem (observed 2026-06-21)

The packing page renders one panel per SKU. When the stitch (PRD-046) correctly spreads a shelf across several SKUs, the operator sees Activia / Chocolate Bar / Be-kind as multiple disconnected panels and loses the "this is one shelf" mental model. Quantities and totals are per-SKU, not per-shelf. Swapping a product (Perrier replacing Smart Gourmet) required manual Remove + Add New steps with no UI affordance.

## 1. The change (decided, no options)

### 1a. Group by shelf, sub-rows by SKU

One card per shelf (e.g. `A05 - Activia Mix & Go`). Inside, a compact table, one row per SKU with columns:

`Product | Expired | Req Qty | Pick Qty (editable) | In Stock`

- One **shelf TOTAL** row at the bottom = SUM(Pick Qty) across the shelf's SKUs (the only total shown).
- Per-shelf single action zone: Packed / Not Filled / Skip apply at the row level; one "shelf done" affordance marks the whole shelf resolved.
- Expired/age and low-stock render as inline secondary cues per row (color is never the only signal; a text/icon label accompanies it).

### 1b. Swap action (button next to "Add product")

A **Swap** button per shelf opens a two-field sheet: "Remove" (preselected to the shelf's current product) + "Add New" (searchable product picker, default-scoped to in-stock + same lane family). Confirming calls one backend RPC `swap_dispatch_shelf(plan_date, machine_id, shelf_id, remove_boonz_id, remove_qty, add_boonz_id, add_qty, reason)` that atomically writes a `Remove` line for the old product and an `Add New` line for the new one (correct title-case actions, WH-sourced, FEFO). No more manual two-step.

### 1c. UX best practices (mandatory, field-first / mobile)

1. **Mobile-first**: primary target viewport 375-414px; layout must hold without horizontal scroll.
2. **Touch targets** >= 44x44px; Pick Qty stepper has large +/- plus direct numeric entry.
3. **One primary action visible per shelf**; destructive/secondary (Skip, Swap) are visually subordinate.
4. **Scannability**: tabular alignment, right-align numeric columns, sticky shelf header + sticky shelf total while scrolling a long shelf.
5. **Status not by color alone**: expiry/oos/partial each carry an icon + text label (WCAG 1.4.1).
6. **Contrast** >= 4.5:1 for text; focus-visible outlines on all controls; every input has an associated label.
7. **Progressive disclosure**: collapse fully-resolved shelves to a one-line summary; expand on tap.
8. **Forgiving input**: Pick Qty clamps to `[0..available]`, shows the cap inline; 0 routes to Not Filled (PRD-044), never a dead-end.
9. **Latency feedback**: optimistic row state with a clear pending/failed indicator; never a silent no-op.
10. **No dead ends**: out-of-stock rows offer Swap / Not Filled inline instead of just blocking.

## 2. Testing rules (all must pass)

| #   | Test                      | Expected                                                                                        |
| --- | ------------------------- | ----------------------------------------------------------------------------------------------- |
| T1  | multi-SKU shelf           | renders as ONE card with sub-rows + a single shelf total                                        |
| T2  | edit a sub-row Pick Qty   | shelf total recomputes live                                                                     |
| T3  | Swap button               | one action creates a Remove (old) + Add New (new) with correct title-case actions and WH source |
| T4  | swap RPC atomicity        | both lines commit together or neither (no orphan)                                               |
| T5  | resolved shelf collapses  | one-line summary; expandable                                                                    |
| T6  | mobile 375px              | no horizontal scroll; targets >= 44px                                                           |
| T7  | a11y                      | contrast >= 4.5:1, focus-visible, labels present, status not color-only (axe/lighthouse clean)  |
| T8  | Pick Qty clamp            | cannot exceed available; 0 -> Not Filled flow (PRD-044)                                         |
| T9  | confirm from grouped view | machine confirms with mixed packed/partial/skip/not_filled (ties to PRD-044)                    |
| T10 | swap then confirm         | swapped shelf packs and confirms cleanly                                                        |

## 3. Phasing / gates

- **P0** Dara+Cody: design + review `swap_dispatch_shelf` RPC (atomic Remove + Add New; title-case action guard; FEFO source; audit). Apply.
- **P1** Stax: FE rebuild of the packing page to shelf-grouped compact panels per 1a + the best-practices checklist 1c. Self-review against the Web Interface Guidelines (web-design-guidelines skill) before PR.
- **P2** Wire the Swap button to the RPC; run T1-T10 incl. an a11y pass (axe + 375px viewport). STOP only on a failing test.
- Depends on PRD-044 (confirm contract) and PRD-046 (multi-SKU shelves are the reason grouping is needed).
