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
| **2** | Field Staff PWA — Driver + Warehouse (AppSheet replacement) | 🔲 Not started | 4–6 weeks |
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
