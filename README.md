# Boonz ERP — Project README

> Smart vending operations platform · UAE · March 2026
> Built for agentic execution — all context an agent needs to pick up any phase and build.

## What this project is

Boonz operates smart vending machines across UAE locations. This ERP platform covers:

- **Field staff PWA** (`/field/*`) — warehouse packing, driver dispatch, pod inventory, config
- **Management ERP** (`/app/*`) — Phase 3, not yet built
- **Client portal** (`/portal/*`) — not yet built

Replaces AppSheet for field operations. Stack: Next.js 15 on Vercel, Supabase (`eizcexopcuoycuosittm`, ap-south-1), n8n VPS, Python refill engine, Claude API.

- **Live URL:** https://boonz-erp.vercel.app
- **GitHub:** boonz-erp (private)

---

## Tech stack

| Layer | Tech |
|---|---|
| Frontend | Next.js 15.x, TypeScript strict, Tailwind CSS |
| Backend | Supabase (PostgreSQL + RLS + Edge Functions) |
| Auth | Supabase Auth (email/password) |
| Hosting | Vercel (auto-deploy on main push) |
| Automation | n8n VPS |
| Notifications | Resend API (email), driver tasks (walk-in suppliers) |

---

## Supabase project

- **Project ID:** `eizcexopcuoycuosittm`
- **Region:** ap-south-1
- **Tables:** 28 base tables

## Test users

| Email | Password | Role |
|---|---|---|
| cyrilsem@gmail.com | (own password) | operator_admin |
| driver@boonz.test | Test1234! | field_staff |
| warehouse@boonz.test | Test1234! | warehouse |

---

## Route structure

```
/field/*              Field staff PWA (warehouse + driver)
/field/packing        Warehouse packing queue
/field/inventory      Warehouse inventory + pending reviews
/field/receiving      PO receiving
/field/orders         Purchase orders list + new PO
/field/dispatching    Driver dispatch per machine
/field/pickup         Driver pickup confirmation
/field/trips          Driver trip overview
/field/tasks          Driver procurement tasks
/field/pod-inventory  Machine stock expiry
/field/expiry         Warehouse expiry monitor
/field/config/*       Config hub (operator_admin only)
  /config/product-mapping    Pod → Boonz product mapping per machine
  /config/pod-products       Pod products + Pod Aliases tab
  /config/boonz-products     Boonz product catalog
  /config/machines           Machine registry + aliases
  /config/suppliers          Supplier list
  /config/product-naming     (deprecated — moved to Pod Aliases)

/app/*                Management ERP — Phase 3 placeholder
/portal/*             Client portal — not yet built
```

## Middleware routing

```
isPublic                              → pass through
!user                                 → redirect /login
field_staff | warehouse               → allow /field/*, block /app /portal
operator_admin | manager | superadmin → allow /field/* and /app/*
finance                               → allow /app/* only
client                                → allow /portal/* only
```

---

## Key files

| File | Purpose |
|---|---|
| `src/middleware.ts` | Role-based routing (working, ignore deprecation warning) |
| `src/app/(field)/field/page.tsx` | Role-aware home — WarehouseHome, DriverHome, OperatorAdminHome |
| `src/app/(field)/components/field-header.tsx` | Smart back nav via `getBackPath()` |
| `src/app/(field)/utils/expiry.ts` | Shared `getExpiryStyle()` colour util |
| `src/app/(field)/components/onboarding/tour.tsx` | SVG spotlight onboarding engine |

---

## Database — key tables

| Table | Rows | Purpose |
|---|---|---|
| `suppliers` | 13 | Supplier master |
| `machines` | 31 | Machine registry |
| `boonz_products` | 258 | Master product catalog |
| `pod_products` | 100 | Machine-facing product catalog |
| `shelf_configurations` | 992 | Per-machine shelf slots |
| `product_mapping` | 5,407 | Pod→Boonz product splits per machine |
| `warehouse_inventory` | ~425 | Warehouse stock batches with expiry |
| `pod_inventory` | ~6,837 | Per-machine stock snapshots |
| `purchase_orders` | ~4,024 | PO lines (flat — po_id groups lines) |
| `refill_dispatching` | ~7,929 | Daily dispatch log per machine/shelf |
| `pod_inventory_edits` | ~10 | Driver stock edit requests (pending review) |
| `product_name_conventions` | 507 | Raw→official name normalisation |
| `machine_name_aliases` | 201 | Legacy machine name aliases |

---

## Architecture decisions (immutable)

1. Single Next.js codebase, 4 route groups
2. n8n is execution arm, Claude issues commands
3. Deterministic pipelines sacrosanct
4. RLS at DB level, not just UI
5. Adyen join: `store_key + date + captured_amount`, exclude pre-06 Feb 2026
6. `machine_product_pricing`: manual population only
7. `createClient()` always inside `useEffect`/async functions, never at module level (SSR fix)

## Known framework notes

- Next.js version is **15.x** — Claude Code may report 16.1.6 but that version does not exist
- `middleware.ts` "file convention is deprecated" warning is a known Next.js 15 warning — does not affect functionality
- `middleware.ts` confirmed working with `export async function middleware()`

---

## Phase 2 — COMPLETE ✅

### Warehouse surface

#### Packing (`/field/packing`, `/field/packing/[machineId]`)

- Shelf-level packing, warehouse stock colour coding
- **FIFO batch display:** all warehouse batches per product allocated FIFO (expiry ASC); single batch: `"Qty: N  Expiry: DD MMM YY"`; multi-batch split: stacked rows on amber background; no stock: amber `"⚠ No stock found"`
- **Edit-then-save pattern** (no instant-save checkbox):
  - Each line: product name → "Recommended: N units" (read-only) → FIFO expiry → stock count → Packed qty input → ✓ Packed / ✗ Skip toggles
  - Green border = packed, dimmed grey = skipped, neutral = unset
  - "Mark all as packed" shortcut; "Confirm packing" disabled until all lines actioned
  - Sequential save: packed → `packed=true, filled_quantity, expiry_date`; skipped → `packed=false, filled_quantity=0, expiry_date=null`
  - After save: green summary bar, read-only mode + Edit button
  - Lines with `packed=true` on load initialise as read-only
- "Return unpicked items" button for packed-but-never-dispatched lines from prior days

#### Receiving (`/field/receiving`, `/field/receiving/[poId]`)

- Receive against PO, auto-populate last known location
- **Multi-expiry batches:** each PO line has `batches[]` array
- "+ Add expiry batch" splits one product into sub-rows with independent qty + expiry
- Running total per line: green = exact, amber = under, red = over
- On confirm: one `warehouse_inventory` row per batch; first batch updates original PO row, extras INSERT new rows with `{poId}-B{n}` batch IDs

#### Inventory (`/field/inventory`, `/field/inventory/[inventoryId]`)

- Flat list with `[A-01]` location badges
- Sort/group by Category/Product/Location/None
- Edit stock + audit log, Inventory Control mode
- **Status filter pills:** All | Active | Expired | Inactive (fetch all statuses, filter client-side)
- Expired rows: red `border-l-4` + "Expired" badge
- **Pending Reviews section** (warehouse/operator_admin/manager only):
  - Collapsible amber header with pending count badge
  - Each edit shows: product, machine, type badge, qty, submitter + time ago
  - Approve: applies edit to `pod_inventory` + `warehouse_inventory` (non-blocking)
  - Reject: marks rejected
  - Dashboard KPI card: "Pod reviews pending" (hides when 0)

#### Orders (`/field/orders`, `/field/orders/new`)

- Pending/All tabs, expandable rows
- Manual entry + Excel import (SheetJS fuzzy match)
- Auto PO ID, required unit price
- Supplier + product dropdowns: fixed (was querying wrong column names)

#### Pod Inventory (`/field/pod-inventory`)

- Machine stock expiry view
- Default filter: All active (not 7-day)
- Sort controls: Expiry / Qty / Product with asc/desc toggle
- Status filter: All active / <3 days / <7 days / <30 days / Expired
- Group by Machine/Product/Category/None
- Data fetch: `limit=10000` (was silently capping at 1000)
- Re-fetch on `visibilitychange` + focus
- **Edit modal — 6 edit types:**
  1. Still in stock → pre-fill `current_stock`
  2. Sold → pre-fill `current_stock` (all gone)
  3. Partial sold → empty qty
  4. Damaged → empty qty
  5. Removed (expired) → pre-fill `current_stock`
  6. Return to warehouse → pre-fill `current_stock`; on approve: pod zeroed, warehouse INSERT as Active

#### Config (`/field/config` + sub-pages — operator_admin/superadmin/manager only)

**Product Mapping** (`/config/product-mapping`):
- Machine-first: no global option, defaults to first machine A→Z
- Group by: By product | By machine | None (flat)
- By machine: 23 machine sections A→Z, Global section hidden
- Accordion: editable splits table with live total bar
- 4-case UPSERT save logic:
  - Case A: `deleted=true + mapping_id` → DELETE
  - Case B: `mapping_id + boonz unchanged` → UPDATE split_pct only
  - Case C: `mapping_id + boonz changed` → DELETE old + INSERT new
  - Case D: `mapping_id=null` → UPSERT with onConflict
- Bulk apply with machine checkboxes
- New mapping modal: machine → pod → splits order, pre-populates existing
- DB: 5,106 per-machine rows across 23 machines (from CSV source of truth)
- RLS: DELETE policy added (was missing — caused silent failures)

**Boonz Products** (`/config/boonz-products`):
- `boonz_product_name = product_brand + " - " + product_sub_brand` (computed, read-only)
- Save blocked if either field empty
- Duplicate check on computed name

**Pod Products** (`/config/pod-products`):
- Two tabs: Products + Pod Aliases
- `custom_code` read-only on edit, auto-generated `PD{NNN}` on add
- Pod Aliases tab: mirrors product-naming — grouped by `official_name`, inline add/remove/rename

**Machines** (`/config/machines`):
- Status filter dropdown
- "+ Add machine" modal (all fields including contact)
- CSV bulk import (preview table, skip existing, add/skip count)
- Aliases tab: grouped by `official_name` with inline add/toggle/delete

**Suppliers** (`/config/suppliers`):
- Standard CRUD

---

### Driver surface

#### Dispatching (`/field/dispatching`, `/field/dispatching/[machineId]`)

- **Edit-then-save pattern** (not instant-save checkbox):
  - Each line: ✓ Added to machine / ↩ Returned toggle buttons
  - Returned lines: reason dropdown (7 options)
  - Comment field always visible per line
  - "Mark all as added" shortcut
  - "Save dispatch" disabled until ALL lines actioned
  - After save: green summary bar, read-only + Edit button
- **Inventory on dispatch:**
  - Added: FIFO warehouse deduction (walks all batches) + `pod_inventory` UPDATE/INSERT
  - Returned: `returned=true`, `return_reason` saved, `warehouse_inventory` INSERT as Active
- Expiry signal: `"⚠ Mixed dates — load oldest first"`
- DB columns: `returned` (bool), `return_reason` (text)

#### Pickup (`/field/pickup`)

- Accordion expand per machine, confirm sets `picked_up=true`

#### Trips (`/field/trips`)

- Read-only overview, 5-tier status badges

#### Tasks (`/field/tasks`)

- Per-line outcome pills, partial qty input, notes, cancel

---

### Dashboard (role-aware)

- **WarehouseHome:** Daily Refills + Procurement + Inventory (with Pod reviews pending KPI) + Configuration
- **DriverHome:** Today's Route + Machine Stock Expiry + Profile
- **OperatorAdminHome:** Daily Refills + Procurement + Inventory + Field Operations (with Pod reviews pending) + Configuration

### Onboarding tour

- Language picker: EN/HI/TA/ML/TL
- SVG spotlight tour with element-anchored tooltips
- Page-level tours: packing, dispatching, inventory, tasks
- `pages_toured` jsonb tracking, "Restart app tour" in Profile

### PO notification flow

- Walk-in suppliers (SUP_005 Union Coop, SUP_011 Carrefour) → `driver_tasks` INSERT
- Others → Resend email to supplier CC info@boonz.me
- Edge Function: `send-po-notification` deployed

---

## Inventory flow — FIFO + dispatch

### Warehouse → Pod flow

1. Refill plan generated (system) → dispatch lines created
2. Warehouse packs (FIFO) → `expiry_date` written to dispatch row
3. Driver picks up → `picked_up=true`
4. Driver dispatches → user chooses Added or Returned per line
5. On Added: warehouse stock decremented (FIFO), `pod_inventory` upserted
6. On Returned: `returned=true`, warehouse stock restored as new Active batch

### Pod inventory edit review flow

1. Driver submits edit (6 types) from pod-inventory page
2. Status = pending → appears in warehouse Inventory → Pending Reviews
3. Warehouse/operator_admin approves:
   - `sold/partial_sold/damaged`: deduct from `pod_inventory`
   - `expired`: pod zeroed + `status=Removed/Expired` + warehouse batch marked Expired
   - `return_to_warehouse`: pod zeroed + warehouse INSERT as Active
4. Rejected: no `pod_inventory` change

---

## RLS summary — key policies

| Table | Policies |
|---|---|
| `product_mapping` | INSERT/UPDATE (admins) + DELETE (admins — critical, was missing) + SELECT (all auth) |
| `pod_inventory` | INSERT/UPDATE (field_staff + warehouse + admins) + SELECT (all auth) |
| `pod_inventory_edits` | INSERT (field_staff) + UPDATE (warehouse + operator_admin + manager) + SELECT (all auth) |
| `warehouse_inventory` | INSERT/UPDATE (warehouse + admins) + SELECT (all auth) |

---

## `pod_inventory_edits` — edit_type values

```
'in_stock' | 'sold' | 'partial_sold' | 'damaged' | 'expired' | 'return_to_warehouse'
```

## `refill_dispatching` — key columns

```
dispatch_id, machine_id, shelf_id, boonz_product_id, pod_product_id
dispatch_date, quantity, filled_quantity, expiry_date
packed, picked_up, dispatched, returned, return_reason, comment
action, include, item_added
```

---

## Open questions

- **OQ-01:** SUP_012 company name unknown
- **OQ-02:** `machine_product_pricing` population strategy
- **OQ-03/04:** `sales_history` NULL enrichment strategy
- **OQ-08:** 22 Feb 2026 Adyen reconciliation discrepancy (PSP SW2LF92JHCLSRLP9, AED 20 vs AED 60)

---

## Phase 3 — NOT YET STARTED

9 modules planned for `/app/*` management ERP. See PRD for full spec.

---

## Common debug patterns

```
Silent RLS 403:       always run execute_sql to diagnose before assuming code bug
RLS policy fix:       CREATE POLICY with EXISTS (SELECT 1 FROM user_profiles
                        WHERE id = auth.uid() AND role IN (...))
JWT claim recursion:  use EXISTS subquery approach, NOT auth.jwt() ->> 'role'
                        in user_profiles policies
Date arithmetic:      CURRENT_DATE + N (integer), not interval syntax
Edge Functions:       Deno.env.get() for secrets, jsr:@supabase/supabase-js@2
                        for imports, verify_jwt: true
createClient():       always inside useEffect/async, never at module level
Supabase row limit:   default 1000 rows — always add .limit(10000) for large
                        tables like pod_inventory
FIFO deduction:       ORDER BY expiration_date ASC NULLS LAST, created_at ASC
                        — walk all batches until qty satisfied
```
