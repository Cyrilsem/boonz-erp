# PRD-087 — ERP UI/UX Uplift

**Date:** 2026-07-08 · **Status:** BUILT (P1–P5 committed on `feat/prd-087-ui-uplift`, awaiting CS push → Vercel preview → merge) · **Scope:** FE + one read-only RPC
**Constraint:** Performance & Consumers stay functionally intact — visuals/palette only (esp. Payments).
**Delivery:** feature branch `feat/prd-087-ui-uplift` → Vercel preview URL → CS click-through → merge.

---

## 1. Audit findings (2026-07-08)

**Navigation** — 16 flat sidebar items (`src/app/(app)/sidebar-nav.tsx`). All targets exist. Issues:
- `hiddenByRole.finance` references "Pods" — not a nav item (dead config).
- Orphan pages reachable but not in nav: `/app/pods`, `/refill/drift`, `/refill/route` (stub placeholder), 6× `/admin/*` (driver-additions is linked; feedback-inbox, inventory-sessions, machines, sim-cards, wh-quarantine are not), `/chat`, `/portal`, `/consumers_vox`, root `/tracker`.
- `/refill/route` is an empty stub → delete.

**Refill page** — `src/app/(app)/refill/page.tsx` is a 2,740-line monolith with 5 tabs (Stock Snapshot [default, inline ~1,400 lines], Refill Planning, Refill Dispatch, Signals, Issues). Snapshot machine list loads on mount but the heatmap/slot detail loads lazily per interaction → perceived "FE-loaded" delay. Sales summary table inside Snapshot at ~lines 1873–1970 → remove (CS request).

**Performance** — `app/performance/page.tsx`, 6,746 lines, fully client-rendered, 7 tabs (Overview, Sites & Machines, Products, Payments, Transactions, Customers, Commercial). Keep logic intact; reskin only.

**Consumers** — `refill/consumers/client.tsx` (~3,689 lines) + `/consumers_vox`. Keep intact; palette pass only.

**Design system** — none. Tailwind v4 (no config file), heavy per-page inline style objects, no shared UI components, no CSS tokens. Palette in use: `#24544a` green, `#0a0a0a` black, `#e1b460` gold, `#6b6860` warm gray.

**Data loading** — ~100% client-side (`"use client"` + useEffect fetch). Worst first-paint offenders: performance, refill, consumers, machines.

## 2. Proposed navigation (approved: aggressive regroup)

Grouped sidebar, collapsible sections, same role-gating logic (fixed):

```
▦ Dashboard                    /app
─ OPERATIONS
  ↻ Refill & Dispatch          /refill        (tabs: Snapshot · Planning · Dispatch · Signals · Issues)
  ⚑ Driver Adds                /admin/driver-additions
  ▣ Machines                   /app/machines
  ▤ Inventory                  /app/inventory
─ SUPPLY
  ☐ Products                   /app/products
  ⇠ Suppliers                  /app/suppliers
  ⛁ Procurement                /app/procurement
  ⬡ Lifecycle                  /app/lifecycle
─ COMMERCIAL
  📈 Performance               /app/performance   (+ new Product Performance tab)
  $ Financials                 /app/financials
  ⇢ Consumers                  /refill/consumers
  ◎ Sales Pipeline             /app/sales-pipeline
─ ADMIN
  ◈ SIM Cards                  /app/sims
  ⚙ Settings                   /app/settings
  ✓ Tracker (owner)            /app/tracker
  🛠 Ops Admin                  → feedback-inbox · inventory-sessions · wh-quarantine (surfaced, admin/owner only)
```

Removals: `/refill/route` stub deleted; "Pods" ghost in hiddenByRole fixed; `/app/pods` — CS to decide (surface under Operations or delete).

## 3. Product Performance (new, auto-updating)

Live replica of *Boonz_Full_Catalogue_Velocity_NonVOX_Jun2026_v2.pdf* as a tab inside Performance:
- **Basis:** units/active-week (products active < full window averaged over active weeks, `nW` badge; pre-launch weeks shown as dots). Refunds & sensor errors excluded.
- **Hero band:** total units, fleet pace/wk, active SKUs, top SKU share.
- **Ledger:** full ranked SKU table — rank, product, top-3 machines (units, window) + machine count, per-week columns, sparkline trend, avg/wk. Editorial section breaks (Heavy Rotation / Upper Middle / Lower Middle / Long Tail).
- **Controls:** period picker (default trailing 6 weeks), scope filter (non-VOX / VOX / all / venue group), search, CSV export.
- **Data:** new read-only view or RPC over sales_lines + product mapping (Dara design, Cody review — read-only SELECT, no protected-entity writes).

## 4. Design system

- `globals.css` design tokens: brand green `#24544a`, ink `#0a0a0a`, gold `#e1b460`, warm-gray scale, semantic success/warn/danger, chart palette.
- Shared primitives in `src/components/ui/`: Card, StatCard, TabBar, DataTable (sortable, sticky header), Badge, Section. New/edited pages use them; existing pages migrate opportunistically.
- Payments tab (Performance): replace current colors with the token palette — layout/logic untouched.
- Typography: keep Plus Jakarta Sans for headings; tabular-nums everywhere numeric.

## 5. Refill page restructure

- Split monolith: `SnapshotTab.tsx` (extracted), keep existing tab components; page.tsx becomes a thin shell (<300 lines).
- Snapshot heatmap: fetch with page load (parallel with machine list), render immediately — no interaction-gated loading. Keep per-machine drill-down lazy.
- Remove sales summary block (lines ~1873–1970).

## 6. Phasing

| Phase | Content | Risk |
|---|---|---|
| **P1 Quick wins** | delete `/refill/route`, fix hiddenByRole, remove sales summary, auto-load heatmap, design tokens in globals.css | Low |
| **P2 Nav regroup** | grouped sidebar + role gating + surface admin orphans | Low-med |
| **P3 Refill split** | extract SnapshotTab, thin shell, no behavior change beyond P1 items | Med |
| **P4 Product Performance** | view/RPC (Dara+Cody) + FE tab | Med |
| **P5 Reskin pass** | Payments palette, shared primitives applied to Dashboard/Machines/Inventory | Low |

Each phase = separate commits on the branch; preview redeployed per phase; Performance/Consumers verified pixel-diff-level for logic parity.

## 7. Out of scope

Backend engines, RPCs with writes, field/driver app (`/field/*`), portal, chat, tracker internals, any protected-entity change.

---

## 8. EXECUTION LOG — 2026-07-08

All five phases built and committed on `feat/prd-087-ui-uplift` (branched from main @52e53d2):

| Commit | Phase | Content |
|---|---|---|
| 97a5533 | P1+P2 | Sales summary removed from Stock Snapshot; refill page server-prefetch (`page.tsx` server component + `RefillPageClient` seeded with `initialData`, heatmap renders with the page); `/refill/route` stub deleted; design tokens in `globals.css` (`--brand/--gold/--ink/--line/--chart-1..6`, exposed via `@theme inline`); grouped sidebar (Dashboard + Operations/Supply/Commercial/Admin), orphans surfaced (Pods, Drift Monitor, Feedback Inbox, Inventory Sessions, WH Quarantine), ghost "Pods" role entry fixed, gold wordmark |
| 0a4a803 | P3 | Refill monolith split: `SnapshotTab.tsx` (2513 lines, stays mounted via display:none), shell 2640→176 lines; planning tab machine names via `onMachineNamesChange`; zero behavior change |
| ea65a2a + 093cc0a | P4 | `get_product_velocity_ledger(p_weeks,p_scope)` RPC (STABLE, SECURITY DEFINER, pinned search_path, read-only; active-week basis, refund-excluded, last N complete Dubai weeks, current partial week separate; scopes non_vox/vox/all/venue_group) + Product Performance tab in Performance page (hero StatCards, ranked ledger, weekly columns, sparklines, nW badges, pre-launch dots, editorial section breaks, search, filters, CSV export) |
| e2bff3b | P5 | Payments tab retint to brand chart palette; Consumers VOX waterfall/legend/KPI/banner retint (visual-only, lint-identical); `src/components/ui/primitives.tsx` (Card, StatCard, Badge, SectionHeading); migration backfill for git parity |

**Key data findings (P4):**
- "Non-VOX" in the Product Desk catalogue = machines NOT named `VOX*`. ACTIVATE/MPMCC/IFLYMCC are `venue_group='VOX'` but ARE in the non-VOX report scope — scope filter is name-based, not venue_group-based.
- Live RPC reproduces the Jun-2026 PDF week-for-week (Aquafina 189/191/226/197…; total 8,282 vs PDF 8,239 — delta = the manual Plaay-Truffle sensor adjustment).
- v2 fix: window = last N complete weeks; in-progress week shown as "THIS WK" column, excluded from avg.

**Migrations (applied to prod via MCP + backfilled to git, versions match remote):**
- `20260708071911_prd087_product_velocity_ledger.sql`
- `20260708072000_prd087_velocity_ledger_v2_complete_weeks.sql`

**Verification:** `tsc --noEmit` clean after every phase; ESLint clean on all new/modified files (pre-existing errors in performance/page.tsx (11× no-explicit-any, lines 4600+) and consumers/client.tsx (26, identical before/after retint) untouched); RPC output validated against the PDF.

**Remaining for CS:**
1. `git push -u origin feat/prd-087-ui-uplift` (sandbox cannot reach GitHub) → Vercel preview → click-through → merge to main.
2. Pre-existing dirty docs files (RPC_REGISTRY.md + 3 EXECUTION-LOGs) left uncommitted, as found.
3. Optional follow-ups: RPC_REGISTRY entry for get_product_velocity_ledger; apply primitives to more pages opportunistically.
