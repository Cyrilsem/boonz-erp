# Boonz ERP — Project README

> Smart vending operations platform · UAE · March 2026  
> Built for agentic execution — all context an agent needs to pick up any phase and build.

---

## What this project is

Boonz operates smart vending machines across UAE locations. This repository contains the full ERP platform: a web app for management, a PWA for field staff, a client portal, and an agentic command layer (Telegram bot + embedded chat GUI) that lets the operator run the company by talking to it.

The system replaces AppSheet for field operations, consolidates Adyen payment data with POS exports, and exposes a Claude-powered agent that can query the database, trigger automation flows, approve dispatch plans, and orchestrate multi-step business operations from a single message.

---

## Repository structure (target)

```
boonz-erp/
├── README.md                        ← this file
├── docs/
│   ├── boonz_erp_phases.docx        ← full phase-by-phase PRD (source of truth)
│   ├── boonz_architecture_v3.html   ← interactive architecture diagram
│   └── db_schema.sql                ← Supabase migration history (exported)
├── supabase/
│   └── migrations/                  ← all DB migrations in order
├── app/                             ← Next.js 14 monorepo
│   ├── (app)/                       ← /app/* management ERP (internal)
│   ├── (field)/                     ← /field/* field staff PWA
│   ├── (portal)/                    ← /portal/* client portal
│   └── (chat)/                      ← /chat/* agentic GUI
├── engines/
│   ├── refill/                      ← Python refill engine (container_runner.py)
│   ├── sales/                       ← sales engine (Phase 7)
│   ├── procurement/                 ← procurement engine (Phase 7)
│   └── finance/                     ← finance engine (Phase 7)
├── agent/
│   ├── tools/                       ← Claude tool definitions (read/write/trigger)
│   ├── telegram_bot.py              ← Telegram webhook handler
│   └── system_prompt.md             ← Claude agent system prompt
└── n8n/
    └── flows/                       ← exported n8n workflow JSONs
```

---

## Tech stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Frontend | Next.js 14 (App Router) on Vercel | TypeScript strict, Tailwind CSS |
| Backend | Supabase (ap-south-1) | Postgres + Auth + RLS + Realtime + Storage |
| Automation bus | n8n (self-hosted VPS) | Schedules, triggers, notifications |
| Domain engines | Python 3.11 + FastAPI (same VPS as n8n) | One engine per vertical |
| Intelligence | Claude API (`claude-sonnet-4-20250514`) | Tool use, streaming, agentic loops |
| Command interface | Telegram Bot API + `/chat` Next.js route | Same Claude agent core |
| Mobile native | Capacitor (Phase 2+) | iOS + Android wrap of Next.js PWA |

---

## Supabase project

- **Project ID:** `eizcexopcuoycuosittm`
- **Region:** ap-south-1 (Mumbai)
- **Plan:** Pro (active)
- **Status:** DB fully migrated ✅ — 20 tables, all populated

### Key table row counts (as of migration)

| Table | Rows |
|-------|------|
| sales_history | 10,336 |
| adyen_transactions | 9,930 |
| refill_dispatching | 7,675 |
| guardrail_products | 6,889 |
| pod_inventory | 6,870 |
| purchase_orders | 3,996 |
| weekly_procurement_plan | 1,514 |
| shelf_configurations | 992 |
| product_mapping | 735 |
| warehouse_inventory | 726 |
| boonz_products | 258 |
| machines | 31 |
| suppliers | 13 |
| machine_product_pricing | 0 ⚠️ needs population |

### Known data issues to be aware of

- `sales_history.boonz_product_id` is NULL for ~10,332/10,336 rows — the source data used generic category names (`Snack Bar`, `Chocolate Bar`) that don't match the `boonz_products` catalog. Not a migration bug — a data enrichment task.
- `sales_history.machine_id` is NULL for 3,445 rows — machine names in the raw export didn't match current aliases due to renaming history.
- `machine_product_pricing` table is empty — needs manual population from known price variance data.
- One known reconciliation discrepancy: 22 Feb 2026 transaction where Adyen and POS totals differ significantly. Flagged in red in the financials module.

---

## Roles

Seven roles are defined. Role is stored in `user_profiles.role` and enforced at both middleware (Next.js) and database (Supabase RLS) levels.

| Role | Surface | Access scope |
|------|---------|-------------|
| `superadmin` | All | Everything across all operators |
| `operator_admin` | Internal app | Full access, scoped to their operator |
| `manager` | Internal app | All modules except billing and user config |
| `finance` | Internal app | Financials + procurement, read-only on ops |
| `field_staff` | Field PWA only | Their trips, pod check-ins, refill confirmation |
| `warehouse` | Field PWA only | Receiving, dispatch, inventory, stock counts |
| `client` | Client portal only | Their machines only, read-only |

---

## Build phases

Full activity lists and acceptance criteria are in `docs/boonz_erp_phases.docx`. Summary:

| Phase | Name | Status | Est. duration |
|-------|------|--------|--------------|
| **1** | Foundation — Auth, roles, DB shell, CI/CD | ✅ Complete | 2–3 weeks |
| **2** | Field Staff PWA — Driver + Warehouse (AppSheet replacement) | 🔄 In progress (P2-S1–S10 ✅, P2-S8 deferred) | 4–6 weeks |
| **3** | Management ERP — 9-module internal platform | 🔲 Not started | 6–8 weeks |
| **4** | Agent Core — Telegram bot + tool definitions | 🔲 Not started | 3–4 weeks |
| **5** | Own GUI Chat — /chat embedded in ERP | 🔲 Not started | 2–3 weeks |
| **6** | Client Portal — daily reports, RLS isolation, alerts | 🔲 Not started | 3–4 weeks |
| **7+** | Domain Engine Expansion — Sales, Procurement, Finance, Market Intel | 🔲 Not started | Ongoing |

---

## Phase 1 — Build log

> Stories P1-S1 through P1-S4 complete. P1-S5 through P1-S8 in progress.

### Completed

#### P1-S1 — Scaffold ✅
- Next.js 15.x scaffolded with TypeScript strict, Tailwind, ESLint, App Router, `src/` dir, `@/*` alias
- 4 route groups created: `(app)`, `(field)`, `(portal)`, `(chat)` — each with `layout.tsx` + `page.tsx` shells
- Auth route group: `(auth)/login/page.tsx` placeholder
- Repo folder structure created: `docs/`, `engines/refill|sales|procurement|finance/`, `agent/tools/`, `n8n/flows/`, `supabase/migrations/`
- `.gitignore` includes `.env`, `.env.local`, `.env*.local`
- `.env.example` committed (no values)

#### P1-S2 — Supabase helpers ✅
- Installed: `@supabase/supabase-js`, `@supabase/ssr`
- `src/lib/supabase/client.ts` — browser client via `createBrowserClient`
- `src/lib/supabase/server.ts` — server client via `createServerClient` with cookie store
- `SUPABASE_SERVICE_ROLE_KEY` not referenced in either file

#### P1-S3 — user_profiles DB ✅
- `user_profiles` table live in Supabase (eizcexopcuoycuosittm)
- RLS enabled, 2 policies: `users_own_profile` (SELECT own row), `admins_manage_profiles` (ALL for superadmin/operator_admin)
- `set_updated_at` trigger active
- `handle_new_user()` trigger on `auth.users` — every signup auto-creates a `user_profiles` row with default role `field_staff`
- 0 security advisories

#### P1-S4 — Auth middleware ✅
- `src/middleware.ts` with `export async function middleware()`
- Session refresh via `supabase.auth.getUser()` on every request (not `getSession()`)
- Unauthenticated requests redirected to `/login?redirectTo=<path>`
- Role-based surface routing: `field_staff`/`warehouse` → `/field`, `client` → `/portal`, all others → `/app`
- `npx next build` ✅ exit 0 · `npx tsc --noEmit` ✅ exit 0
- Known: deprecation warning `"middleware" file convention is deprecated` emitted by Next.js 15 — does not affect functionality, safe to ignore

#### P1-S5 — Login page ✅
- `src/app/(auth)/login/page.tsx` — server wrapper with Suspense boundary
- `src/app/(auth)/login/login-form.tsx` — `'use client'` form
- Email + password sign-in via `supabase.auth.signInWithPassword()`
- Inline error display below form (not toast)
- Forgot password via `resetPasswordForEmail()`
- On success: `router.push('/app')` — middleware handles role redirect
- `npx next build` ✅ · `npx tsc --noEmit` ✅

#### P1-S6 — Management sidebar ✅
- `src/app/(app)/layout.tsx` — server component, fetches role from `user_profiles`
- `src/app/(app)/sidebar-nav.tsx` — `'use client'` collapsible sidebar
- 9 nav items: Dashboard, Pods, Refill & Dispatch, Products, Inventory, Financials, Suppliers, Consumers, Settings
- Role filtering: finance hides Pods/Refill/Consumers · manager hides Settings
- Active route highlighted via `usePathname()`
- Collapses to icon-only below 768px
- `npx next build` ✅ · `npx tsc --noEmit` ✅

#### P1-S7 — Field bottom nav ✅
- `src/app/(field)/layout.tsx` — renders children above tab bar
- `src/app/(field)/bottom-tabs.tsx` — `'use client'` fixed bottom tab bar
- 4 tabs: Trips, Pods, Inventory, Profile
- Minimum 44px height, active tab highlighted via `usePathname()`
- Client-side navigation via Next.js `Link` (works offline)
- `npx next build` ✅ · `npx tsc --noEmit` ✅

### Pending

#### P1-S8 — CI/CD ✅
- GitHub repo: `boonz-erp` private, `main` + `dev` branches
- Vercel: live at `boonz-yk7fo2632-cyril-semaans-projects.vercel.app`
- Env vars: `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY` (Production + Preview), `SUPABASE_SERVICE_ROLE_KEY` (Production only)
- Branch ruleset `main` created (enforcement: disabled until team grows)
- End-to-end login verified: `cyrilsem@gmail.com` → `operator_admin` → `/app` ✅

### Phase 1 — Complete ✅

---

## Phase 2 — Build log

### Completed

#### P2-S1 — Driver trip stop list ✅
- `src/app/(field)/trips/page.tsx`
- Queries `refill_dispatching` WHERE dispatch_date = today AND include = true AND picked_up = true
- Groups by machine, shows `official_name`, pod_location, SKU count badge, dispatched status
- Empty state: "No stops for today"

#### P2-S2a — Warehouse packing view ✅
- `src/app/(field)/packing/page.tsx` — machine list with packed progress
- `src/app/(field)/packing/[machineId]/page.tsx` — shelf-slot detail
- Groups lines by `shelf_code`, shows `pod_product_name`, planned quantity
- Warehouse stock shown with colour coding: green (stock ≥ planned), amber (stock < planned), red (stock = 0)
- Checkbox per line writes `packed = true` to `refill_dispatching`
- "Mark all packed" button for full machine

#### P2-S2b — Driver pickup confirmation ✅
- `src/app/(field)/pickup/page.tsx`
- Shows machines where all lines packed = true
- "Confirm pickup" sets `picked_up = true` for all lines on that machine
- Only enables button when machine is fully packed

#### P2-S3 — Driver refill at machine ✅
- `src/app/(field)/trips/[machineId]/page.tsx`
- Check-in via `navigator.geolocation` — writes to `trip_events`
- Haversine distance calculation — warns at > 200m variance
- Refill lines grouped by `shelf_code`, quantity inputs pre-filled with planned qty
- Submit writes `filled_quantity` + `dispatched = true` to `refill_dispatching`
- Basic offline queue via IndexedDB

#### P2-S4 — Expired/damaged removal ✅
- `src/app/(field)/trips/[machineId]/removals/page.tsx`
- Select product, quantity, reason (Expired/Damaged/Other)
- Inserts into `pod_inventory` with status = 'Removed / Expired'

#### P2-S5 — Machine issue report ✅
- `src/app/(field)/trips/[machineId]/issue/page.tsx`
- Issue type dropdown, description, optional photo
- Photo compressed to < 1MB via canvas before upload
- Uploads to Supabase Storage: `machine-issues/{machineId}/{timestamp}.jpg`
- Inserts into `machine_issues`

#### Nav fix — role-based bottom tabs ✅
- `src/app/(field)/bottom-tabs.tsx`
- Initial state `null` — prevents flash of wrong nav
- `warehouse` → Packing, Inventory, Profile
- `field_staff` → Trips, Pickup, Inventory, Profile

#### RLS recursion fix ✅
- `admins_manage_profiles` policy was querying `user_profiles` inside a `user_profiles` policy — infinite recursion → 500 for all users
- Fixed: use `auth.jwt() ->> 'role'` instead of subquery

#### Driver flow restructure ✅
- Bottom nav for `field_staff`: **Trips, Pickup, Dispatching, Profile**
- **Trips** (`/field/trips`) — read-only overview of all today's machines, 5-tier status badges: Done / In progress / Ready to dispatch / Ready for pickup / Packing...
- **Pickup** (`/field/pickup`) — two sections: "Ready for pickup" (accordion with all packed items, confirm button sets `picked_up=true`) and "Collected"
- **Dispatching** (`/field/dispatching`) — two sections: "To dispatch" and "Completed". Only shows machines where all lines `picked_up=true`
- **Dispatching detail** (`/field/dispatching/[machineId]`) — lines grouped by shelf, checkbox sets `dispatched=true` + `filled_quantity` + `item_added=true`, comment field saves on blur, "Mark all dispatched" button
- Middleware: `field_staff` login redirects to `/field/trips`

#### Packing list refresh fix ✅
- `fetchMachines` extracted as `useCallback`
- `visibilitychange` + `focus` listeners re-fetch on return from detail page

#### Comment field added ✅
- `packing/[machineId]/page.tsx` — comment input per line, saves on blur to `refill_dispatching.comment`
- `trips/[machineId]/page.tsx` — same pattern, included in submit alongside `filled_quantity`

#### DB migrations applied ✅
- `refill_dispatching.packed boolean DEFAULT false`
- `refill_dispatching.picked_up boolean DEFAULT false`
- `trip_events` table — RLS on, 2 policies
- `machine_issues` table — RLS on, 3 policies

#### Test users ✅
- `driver@boonz.test` — role: `field_staff`
- `warehouse@boonz.test` — role: `warehouse`

#### P2-S6 — Warehouse receiving against PO ✅
- `src/app/(field)/field/receiving/page.tsx` — list of pending POs (received_date IS NULL)
- `src/app/(field)/field/receiving/[poId]/page.tsx` — editable received qty, expiry date, location per line
- On confirm: marks PO lines received + inserts into `warehouse_inventory` with batch_id
- Overage warning (amber, non-blocking)
- RLS policies added: `warehouse_can_receive_pos` (UPDATE on purchase_orders), `warehouse_can_insert_inventory` + `warehouse_can_update_inventory` (on warehouse_inventory)

#### P2-S7 — Expiry sweep ✅
- `src/app/(field)/field/expiry/page.tsx`
- Filter pills: All active | Today | 3 days | 7 days (default) | 30 days
- Colour coding: red (expired) · amber (≤3d) · orange (≤7d)
- Remove button sets `status = 'Expired'`
- Sorted by nearest expiry first

#### Warehouse bottom nav ✅
- Packing | Receiving | Expiry | Profile

#### P2-S9 — WH Inventory + Audit ✅
- `src/app/(field)/field/inventory/page.tsx` — grouped by wh_location, search + expiry filter pills, sort controls
- `src/app/(field)/field/inventory/[inventoryId]/page.tsx` — edit stock toggle, audit log insert, last 10 audit history with delta + reason + who
- DB: `inventory_audit_log` table created with RLS
- RLS: `warehouse_can_read_inventory` SELECT + `warehouse_can_log_audits` INSERT

#### P2 Refinement pass ✅ (bb09c55)
- **Dashboard expiry KPIs**: 4 separate cards — Expired (23) · <3 days (12) · <7 days (16) · <30 days (64) — correct date range queries
- **Machines today**: renamed "To refill today" + packing shown as % (e.g. "44%") with sub-label "{n} of {n} lines"
- **Inventory control KPI**: "Last inventory control" card — red if never/>30 days, amber 8–30 days, green ≤7 days
- **Inventory control mode**: "+ Inventory Control" button → inline edit all rows → Complete logs to `inventory_control_log` + `inventory_audit_log`
- **Flat inventory list**: location shown as inline badge [A-01], sort by expiry/location/name/qty
- **FieldHeader component**: shared "← Home" + title bar on all 15 sub-pages
- **Bottom tabs**: visible only on /field home, hidden on all sub-pages
- **PO form**: read-only auto-generated ID, unit price required, expiry date removed (set at receiving)
- **Receiving location**: auto-populated from most recent known location per product

#### Config pages — naming rules, auto-codes, machine add, pod aliases ✅
- **Boonz Products**: `boonz_product_name` removed from form → computed as `brand + " - " + sub_brand` · live preview · both fields required · duplicate check on computed name
- **Pod Products**: `custom_code` read-only on edit · auto-generated `PD{NNN}` on add (fetches max PD### + increments) · two tabs: Products + Pod Aliases
- **Pod Aliases tab**: mirrors old product-naming page · grouped by official_name · inline add/remove/rename · moved out of config hub
- **Machines**: status filter dropdown · `+ Add machine` modal (all fields) · CSV bulk import (preview table, skip existing, add/skip count) · Aliases tab rebuilt grouped by official_name with inline add/toggle/delete
- **Config hub**: Product Naming card removed (now lives in Pod Products → Pod Aliases tab)
- **Root cause**: missing DELETE RLS policy on product_mapping — all deletes silently failed
- **RLS fix**: added `admins_manage_mapping_delete` + fixed UPDATE WITH CHECK
- **4-case save logic**:
  - Case A: deleted=true + mapping_id → DELETE by mapping_id
  - Case B: mapping_id + boonz unchanged → UPDATE split_pct only
  - Case C: mapping_id + boonz changed → DELETE old + INSERT new (key column can't be updated)
  - Case D: mapping_id=null → UPSERT with onConflict
- `original_boonz_id` tracks the loaded value to detect Case C
- Sequential saves (not parallel) to prevent race conditions
- Inline error display in accordion + console.error on every failure
- **DB**: 5,106 per-machine rows across 23 machines (from CSV source of truth) · 227 global reference rows kept but hidden from UI · every machine has its own complete split set

#### Pod inventory display + inventory flow fixes ✅
- **Root cause of blank pod-inventory page**: Supabase JS client default 1,000 row cap — table has 5,587 active rows, ADDMIND/HUAWEI entries were beyond position 1,000 and never loaded. Fixed with `.limit(10000)`
- **Default filter**: changed from `'7days'` to `'all'` — newly dispatched healthy stock now visible immediately
- **Re-fetch on navigation**: added `visibilitychange` + `focus` listeners so page refreshes when navigating back to it
- **Inventory flow confirmed working end-to-end**:
  - FIFO warehouse deduction (walks all batches until qty satisfied)
  - Pod inventory UPDATE when existing row found (ADDMIND: 5+15=20 ✅)
  - Pod inventory INSERT when no row exists (HUAWEI: 0+8=8 ✅)
  - RLS: added INSERT + UPDATE policies for field_staff on pod_inventory
- **Root cause**: warehouse deduction and pod inventory update were coupled — if no warehouse batch found, pod update was skipped entirely
- **Fix 1 (packing)**: always writes `expiry_date = fifoExpiry ?? null` to refill_dispatching even when no warehouse stock exists
- **Fix 2 (dispatching)**: `runInventoryUpdates` fully decoupled — warehouse deduction and pod update are independent; pod update always runs regardless of warehouse outcome
- **Data fix**: seeded Yan Yan warehouse stock (both variants, B-02, expiry Jul 2026)
- **Packing detail**: FIFO batch allocation per product (ORDER BY expiry ASC) · "Qty: N  Expiry: DD MMM YY" per batch in expiry colour · multi-batch on amber bg · no stock warning · on tick: writes expiry_date to refill_dispatching
- **Dispatching detail**: reads expiry_date from dispatching rows · expiry shown below product name · detects mixed dates → amber "⚠ Mixed dates — load oldest first"
- **On dispatch**: deducts warehouse_inventory batch (match by boonz_product_id + expiry_date, FIFO fallback) · upserts pod_inventory · non-blocking — dispatch never blocked by inventory failures
- **Machine-first UI**: no global option in dropdown · defaults to first machine A→Z · "Showing splits for: [machine]" subtitle
- **UPSERT save**: UPDATE by mapping_id for existing · upsert for new (no more unique constraint errors) · DELETE by mapping_id for removed rows
- **New mapping modal**: machine → pod → splits order · pre-populates from existing machine splits · "Update/Create mapping" label
- **By machine view**: global section removed · 23 machine sections A→Z only
- **By product view**: machine name shown on right of each row
- Machine dropdown fix: removed incorrect `.eq('status', 'active')` case mismatch — now fetches all 31 machines unconditionally
- Group by pills: By product (default) | By machine | None (flat table)
- By machine: all machines as section headers (Global first, then A→Z) with pod products underneath — same product appears under each machine that has a mapping
- None: flat read-only table (pod name, boonz name, split%, machine, status)
- Accordion compound key `podId|||machineId` — same pod product opens independently per machine section
- `loadMappings` fetches all rows in one call, grouping is entirely client-side via useMemo
- **Product Mapping**: machine selector (Global/per-machine) · pod-product grouped list · red border-l-4 on ≠100% rows · accordion with editable splits (boonz dropdown + %, live total bar) · DELETE+INSERT save · bulk apply with machine checkboxes + confirm · add-new modal · deduplicates by mapping_id
- **Product Naming**: official-name-first view · alias count badge · accordion shows all variants · inline add-alias + × remove · rename official name (updates all rows) · add-new modal with duplicate check · deduplicates by (original_name, official_name)
- `operator_admin` / `manager` / `superadmin` → `OperatorAdminHome` (5 sections)
- **Daily Refills** — same 2×2 as WarehouseHome
- **Procurement** — open POs · received today · New PO CTA
- **Inventory** — warehouse stock + machine stock expiry with last-control indicator
- **Field Operations** — driver tasks · ready to collect · to dispatch · expired in machines
- **Configuration** — 4-count grid (Boonz products / Pod products / Suppliers / Mappings)
- Middleware: `opsRoles = ['superadmin','operator_admin','manager']` → `/field`
- Tour: `field_staff` → driverTour · all others → warehouseTour
- Unknown role → friendly fallback message
- `/reset-password` — handles Supabase recovery token from URL hash · password + confirm fields · `updateUser({ password })` → sign out → `/login` · middleware passes through unauthenticated users on this route
- **`/field/config`** hub — role-guarded (operator_admin/superadmin/manager only) · 6 nav cards with live counts
- **Product Mapping** — pod→boonz bridge · split_pct warning · global/machine filter
- **Boonz Products** — attribute chips · category datalist · duplicate name check
- **Pod Products** — supplier dropdown · add-new
- **Machines** — two-tab (Machines/Aliases) · alias CRUD · no add-new (provisioned externally)
- **Suppliers** — 4 collapsible field groups · filter pills · auto-generate supplier_code
- **Product Naming** — original→official lookup · boonz_products datalist
- **Dashboard** — Config SectionCard added to WarehouseHome (role-guarded)
- **RLS policies** — 12 INSERT/UPDATE policies across all 6 tables for admin roles
- **SSR fix** — `createClient()` moved inside async functions (not module-level)
- **`tour.tsx`** rewritten: SVG mask overlay with cutout hole · blue highlight ring · smart tooltip positioning (preferred→bottom→top→right→left→center with viewport clamping) · CSS triangle arrows · animated step dots · resize handling · tap target advances tour
- **`use-page-tour.ts`**: custom hook checks `pages_toured` jsonb · only fires after dashboard onboarding complete · spreads existing keys on update
- **`translations.ts`**: TourStep type adds `targetId` + `tooltipPosition` · page tours for packing (3 steps) / dispatching (3 steps) / inventory (2 steps) / tasks (2 steps) · all 5 languages
- **`data-tour` attributes**: all SectionCards on warehouse + driver home · packing-list / packing-status / dispatch-photos / dispatch-lines / inventory-filters / inventory-list / task-card

#### Training data ✅ — 6 days (Mar 19–24)
| Date | Machines | State |
|---|---|---|
| Mar 19 (today) | 3 | Partial packing in progress |
| Mar 20 | 4 | Nothing packed yet |
| Mar 21 | 3 | All packed, awaiting pickup |
| Mar 22 | 4 | 2 dispatched, 2 in pickup |
| Mar 23 | 4 | All complete — green dashboard |
| Mar 24 | 2 | Fresh quiet day |

- 5 open POs (PO-TRAIN-001 to 005) across 5 days
- 2 driver tasks: Union Coop Day 4, Carrefour Day 5
- Both test users: `onboarding_complete=false`, `preferred_language=null` — tour triggers on next login
- **`translations.ts`**: 5 languages (EN/HI/TA/ML/TL) × 2 roles (warehouse 8 steps, driver 6 steps) · `wSteps()` factory deduplicates button labels · all button labels localised per language
- **`language-picker.tsx`**: full-screen modal in English · 5 flag+name buttons · selection highlights blue with ✓ · Continue disabled until selection made
- **`tour.tsx`**: fixed bottom sheet + dark backdrop · animated step dots (pill=visited, circle=upcoming) · "Step N of M" counter · last step becomes green "Get started ✓"
- **`field/page.tsx`**: `hasCheckedOnboarding` ref prevents re-trigger · language picker → tour sequence · saves `preferred_language` + `onboarding_complete` to user_profiles · "Restart app tour" in Profile section
- **Daily Refills machine-level stats**: `MachineStats` map groups lines by machine_id · `packedMachines/pickedUpMachines/dispatchedMachines` = machines where ALL lines complete · display as "2/3" fraction · `ratioCardStyle(count, total)` — gray(no data)/green(done)/yellow(progress)/red(not started) · Driver home pickup-ready + to-dispatch also machine-level
- **Warehouse inventory grouping**: Category · Product · Location · None (default) · `InventoryGroup` useMemo · Location groups sorted A→Z · Category/Product sorted totalUnits DESC · row props adapt per groupBy (hide redundant field when it's the section header)
- **Dashboard full redesign**: 3 sections (Daily Refills · Procurement · Inventory), 2-column grid within each, white cards with shadow
- **Daily Refills**: Machines today · Packing % · Picked up % · Dispatched % — all with `pctCardStyle` (green=done, yellow=progress, red=not started)
- **Procurement**: Open orders · Received today · full-width dashed "+ New Purchase Order" CTA
- **Inventory**: Last control inline in header · Warehouse stock 2×2 · Machine stock 2×2 — all using `kpiCardStyle`
- **Driver home**: Today's Route section (stops/pickup/dispatch/tasks) + amber banner for pending tasks · Machine Stock Expiry 2×2 · Profile with sign out
- **Shared expiry util**: `src/app/(field)/utils/expiry.ts` — `getExpiryStyle()` + `ExpiryStyle` interface exported, imported by pod-inventory, inventory, and page.tsx
- **Dashboard KPI cards colour scale**: `kpiCardStyle(count, urgency)` — all 8 expiry cards (4 warehouse + 4 machine stock) on both WarehouseHome and DriverHome · count=0 → green ✓ · critical/high → red · medium → yellow · low → lime
- **Expiry colour scale**: `getExpiryStyle()` single source of truth — green (>30d) → lime (8–30d) → yellow (4–7d) → light red (≤3d) → red (expired) · exact day count labels ("14d left", "Today") · null = no badge · applied to both `pod-inventory/page.tsx` and `inventory/page.tsx`
- **Pod inventory universal grouping**: all filters now support Machine | Product | Category | None grouping · machine dropdown (derived from filtered data) · defaults per filter: Expired/<3d/<7d → Machine, <30d → Category, All → None · `SectionHeader` component extracted · `rowProps()` helper controls showMachine/showCategory/showProduct per group type · summary line adapts to context
- **Pod inventory expired view**: grouped by machine (not category) · sorted by totalUnits DESC · items within machine by expiry ASC → name ASC · `showCategory` prop toggles machine name vs category on `PodRowItem` · summary line shows "N machines · N items · N units expired"
- **Pod inventory zero-stock excluded**: `.gt('current_stock', 0)` at DB level — summary line also updated
- **Expired view grouped by category**: `CategoryGroup` interface + `groupedByCategory` useMemo — section headers show category name + item count + units · null category → "Uncategorised" · other filters stay flat
- **`PodRowItem` component**: extracted to avoid render duplication between grouped and flat views
- **Pod inventory status filter**: all 3 queries (warehouse KPI, driver KPI, pod-inventory list) now use `.eq('status','Active')` — excludes Inactive (430), NULL (74), Removed / Expired (74), Removed/ Expired (8). Only the 6,284 Active rows included.
- **Pod inventory expiry KPIs**: "Machine Stock Expiry" section on both warehouse and driver home — 4 cards (Expired in machines: 520 · <3d: 58 · <7d: 118 · <30d: 348) — single fetch, client-side bucketing
- **Pod inventory page** (`/field/pod-inventory`): filter pills, search, summary line "N items · N units at risk", large right-aligned qty with colour coding, expiry badge prominent, sorted by expiry ASC
- **Warehouse inventory qty emphasis**: right-side layout with large bold qty + "units" label, coloured by urgency
- **Task accordion PO lines**: fixed `!inner` join hint → plain join · `po_line_id` added to select · state maps keyed by UUID not product name · `allLinesHaveOutcome` checks by `po_line_id`
- **PO lines seeded**: PO-2026-DEMO (3 lines) and PO-2026-UNION (2 lines) now have real purchase_orders rows
- **Per-line task outcomes**: outcome pills (✅⚠️❌💰🗓️📝) on each product row inside accordion · partial qty input per line · optional note per line · "Mark as collected" disabled until all lines have outcome · full line detail stored as JSON in outcome_comment
- **Bottom nav removed**: `bottom-tabs.tsx` returns null — home category cards + FieldHeader are sole navigation
- **Smart back navigation**: `getBackPath()` in FieldHeader resolves correct parent — L3→L2→L1→/field, never jumps to home unexpectedly
- **FieldHeader everywhere**: 17 files fixed — header on all states (loading/empty/error/submitted) + profile page added
- **Open PO KPI**: counts distinct po_id via `new Set()` — shows 2 not 5
- **Driver task KPI**: includes `acknowledged` status — shows 2 open tasks correctly
- **Dashboard layout**: "Last control" moved to KPI row 1 beside Open POs · "Expiry Alerts" section title added above 4 expiry cards
- **Bottom tabs**: confirmed only on /field home
- **Driver Tasks**: expandable accordion with PO line details table + 6 outcome options (purchased full/partial/not available/price too high/expired on shelf/other) + partial qty input + notes + cancel

#### DB additions ✅
- `driver_tasks.outcome` text CHECK (6 values)
- `driver_tasks.outcome_comment` text
- `driver_tasks.outcome_qty` numeric
- `src/app/(field)/field/page.tsx` — role-aware home screen
- Greeting + formatted date header
- 4 KPI cards: Machines today, Packed progress, Expiring ≤3 days, Pending orders
- 4 category cards: Daily Refills, Inventory Management (red alert if critical expiry), Procurement, Profile
- Skeleton loading + visibility/focus re-fetch

#### P2-S15 — Driver landing page ✅
- Same file, detects warehouse vs field_staff role on mount
- 4 KPI cards: Stops today, Ready to collect, To dispatch, Open tasks
- 3 activity cards: Today's Route, Tasks (amber alert if pending), Profile
- Middleware updated: both roles redirect to /field (home handles routing)

### Pending

#### P2-S8 — Offline sync engine 🔲 (deferred)

---

### Definition of done (Phase 1)

- [ ] Next.js app deployed to Vercel, preview URL accessible
- [ ] Login page works — can sign in with a test account
- [ ] All 7 roles redirect to their correct surface after login
- [ ] Unauthenticated routes redirect to `/login`
- [ ] Supabase RLS tested — a `client` role user cannot query `machines` outside their client scope
- [ ] GitHub repo created, `main` and `dev` branches exist, Vercel connected
- [ ] `supabase/migrations/` folder committed with at least the first migration

---

## Agent system prompt (Phase 4+)

When building the Telegram bot and `/chat` GUI, initialise Claude with this system prompt:

```
You are the Boonz operations agent. You help the operator run the company.

You have access to the following tools:
- Database query tools (read-only): get_machine_status, get_sales_summary, 
  get_inventory_levels, get_dispatch_plan, get_trip_status
- Action tools (write, require confirmation): approve_dispatch_plan, 
  flag_transaction_discrepancy, update_stock_level
- n8n trigger tools (require confirmation): trigger_refill_engine, 
  send_client_report, send_supplier_notification, reschedule_cron

Rules:
1. Always answer in plain language. Never expose raw JSON or SQL to the user.
2. For any action or trigger tool: summarise what you are about to do and ask 
   for confirmation before executing. Wait for "yes", "confirm", or "do it".
3. Confirmations expire after 60 seconds.
4. If a tool call fails, explain the error plainly and suggest next steps.
5. Proactively flag anomalies you notice while answering a question.
6. The current operator context is: {operator_name}. Only surface data for 
   this operator's machines and clients.

Business context:
- Currency: AED (UAE Dirhams)
- Two machine types: VOX machines and Boonz machines
- Active locations include: Mercato, DIFC, and others
- Reconciliation: Adyen is the payment processor; POS is the vending system export
- A known reconciliation discrepancy exists for 22 Feb 2026 — treat this as 
  flagged, do not attempt to auto-resolve it
```

---

## n8n flows (existing)

The following n8n flows are already partially built or designed. An agent building Phase 4 should wire Claude's tool calls to fire these webhooks:

| Flow | Trigger | What it does |
|------|---------|-------------|
| `ingest_adyen` | Adyen webhook | Receives payment event → writes to `adyen_transactions` |
| `ingest_vox_export` | Manual / scheduled | Processes VOX CSV export → writes to `sales_history` |
| `trigger_refill_engine` | Cron (configurable) or webhook | Calls refill engine FastAPI endpoint → polls for result |
| `notify_manager` | Supabase Realtime (machine_issues insert) | Sends Telegram message to manager |
| `daily_client_report` | Cron 08:00 daily | Generates PDF → uploads to Storage → emails client |
| `send_supplier_alert` | Webhook (agent-triggered) | Sends email/WhatsApp to supplier |

Webhook URLs format: `https://<n8n-host>/webhook/<flow-id>`

---

## Refill engine (existing Python pipeline)

Location: `engines/refill/`  
Entry point: `container_runner.py`

### Stages

**Stage 1 — Ingest + clean**
- Inputs: `TodayOrder.xlsx`, `HistoryOrder.xlsx`, `AisleInfo.xlsx`
- Outputs: `master_sales_transactions.csv`, `master_sales_baskets.csv`, `inventory_mapping.csv`

**Stage 2 — Optimise (9-module pipeline)**
1. Feature Engine
2. Classify
3. Expiry
4. Demand Forecast
5. Optimize
6. Mix Floor
7. Assortment
8. Post-process
9. Dispatch

- Outputs: `refill_instructions_CS.csv`, `dispatching_list.csv`, `procurement_list.csv`

**Stage 3 — Owner review**
- CLI: `reasoning_cli.py` — presents recommendations, accepts overrides
- Outputs: `refill_instructions_final.csv`, `dispatching_list_final.csv`, `change_log.md`

In Phase 3 (Management ERP), Stage 3 moves from CLI to a web interface. In Phase 4+, the Claude agent can trigger Stage 1+2 via n8n, then assist the owner through Stage 3 via Telegram or `/chat`.

---

## Environment variables reference

All variables live in `.env` at the project root. Never commit this file.

| Variable | Phase needed | Description |
|----------|-------------|-------------|
| `NEXT_PUBLIC_SUPABASE_URL` | P1 | Supabase project URL — public safe |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | P1 | Supabase anon key — public safe |
| `SUPABASE_SERVICE_ROLE_KEY` | P1 | Full DB access — **server only, never expose to client** |
| `ANTHROPIC_API_KEY` | P4 | Claude API — usage-billed |
| `TELEGRAM_BOT_TOKEN` | P4 | Bot token from BotFather |
| `TELEGRAM_ALLOWED_USER_IDS` | P4 | Comma-separated Telegram user IDs for whitelist |
| `N8N_WEBHOOK_BASE_URL` | P4 | Base URL for n8n webhook triggers |
| `REFILL_ENGINE_URL` | P4 | FastAPI base URL on VPS |

---

## Decision log

Decisions made during architecture sessions that an agent should not reverse without explicit instruction:

1. **Single Next.js codebase, 4 route groups** — not separate apps. Reason: shared auth, shared components, single deployment.
2. **n8n is the execution arm, not Claude** — Claude issues commands; n8n runs them. Claude never calls external APIs directly except Supabase via tool definitions.
3. **Deterministic pipelines are sacrosanct** — Claude reasons on engine outputs but never replaces the Python pipeline. The numbers come from the engine; the interpretation comes from Claude.
4. **RLS enforced at DB level, not just UI** — every permission gate exists as a Supabase RLS policy. UI-level hiding is cosmetic only.
5. **Adyen reconciliation join logic** — match on: `store_key` + `date` + `captured_amount = pos_total_paid`. Exclude pre-06 Feb 2026 rows (test transactions).
6. **machine_product_pricing table is empty** — do not attempt to populate it programmatically. Requires manual input from the operator.

---

## Contact / ownership

Project: Boonz Smart Vending ERP  
Built with: Claude (Anthropic) as architecture and development partner  
Last updated: March 2026
