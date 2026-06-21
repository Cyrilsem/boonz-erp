# PRD-047 - Packing page UX: shelf-grouped panels + one-tap Swap

**Status:** ✅ PARTIAL 2026-06-21 - backend P0 (swap_dispatch_shelf) APPLIED to prod; P1/P2 FE (shelf-grouped page + Swap wiring + a11y) = NEEDS IMPLEMENTATION + DEPLOY. swaps_enabled untouched (false).

## EXECUTION LOG (2026-06-21)

- **P0** `prd047_p0_swap_dispatch_shelf` APPLIED. New `swap_dispatch_shelf(p_plan_date, p_machine_id, p_shelf_id, p_remove_boonz_id, p_remove_qty, p_add_boonz_id, p_add_qty, p_reason)` DEFINER. Composes the canonical `add_dispatch_row` twice in one transaction (atomic): a `Remove` (old product, source unknown) + an `Add New` (new product, source_kind='wh' = machine primary warehouse; FEFO batch chosen at pack). Title-case action guard, role gate, mapping check, and edit-log audit all inherited from add_dispatch_row. Grants authenticated/service_role. Cody Art 1/4/8/12.
- **Tests (BEGIN..ROLLBACK, VOXMCC-1005 A01):** T3 swap → 1 Remove + 1 Add New, source=wh, title-case ✓; T4 atomicity → bogus add raises and the Remove rolls back too (0 orphan lines) ✓.
- **DEFERRED (FE, NEEDS IMPLEMENTATION + DEPLOY):** P1 shelf-grouped compact cards (one card/shelf, sub-rows Product|Expired|Req|Pick|In Stock, one shelf total), per the 1c best-practices checklist (mobile-first 375px, 44px targets, status-not-color-only, WCAG AA, progressive disclosure, no dead ends); P2 Swap button wired to `swap_dispatch_shelf` + confirm-from-grouped-view (PRD-044 two-button). Backend RPC now exists; T1/T2/T5-T10 are FE/a11y tests to run after implementation. Pairs with PRD-044 FE + PRD-046 (multi-SKU shelves).
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
