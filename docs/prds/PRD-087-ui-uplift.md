# PRD-087 — ERP UI/UX Uplift

**Date:** 2026-07-08 · **Status:** PROPOSAL (awaiting CS approval) · **Scope:** FE only, no backend/RPC changes
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
