# PROD-SYNC PRD-058 + PRD-059 — close-out log

Date: 2026-06-25. Code sync only (both migration sets were ALREADY applied to prod via MCP; nothing re-applied to the DB).

## Outcome

- PR **#5** `feat/prd-058-059-prod-sync` → **merged to `main`** (merge commit `f6195be`), parents `0bf597d` (PRD-058) + `13f69c0` (PRD-059).
- `main` fast-forwarded `2153e25` → `f6195be`. The 12 prod-sync files landed exactly:
  - 6 migrations: `prd058_tunable_priority_weights` + `prd059_ws2_resolve_shelf_backfill` / `ws3_no_mapping_inactive` / `ws4_highlight_orphan_writeoff` / `ws5_inactive_cleanup` / `ws6_drawer_expiry_truth`
  - FE: `src/app/(app)/refill/page.tsx`
  - registries: CHANGELOG / MIGRATIONS_REGISTRY / METRICS_REGISTRY
  - PRD docs: PRD-058, PRD-059
- Prod parity (read-only): MIGRATIONS_REGISTRY lists all 6 migrations as ✅ Applied to prod. No `apply_migration`, no DB writes.
- swaps_enabled stays false; `engine_add_pod` / `engine_swap_pod` unmodified.

## Prod deploy — CONFIRMED

- Vercel deployed `main`; `record-prod-deploy` logged **`06737fb chore(deploy): record production f6195be [skip ci]`** — merge `f6195be` (PRD-058+059) is live on prod (real sha). `origin/main` then advanced with further deploy records (HEAD `ef7e106`).

## Stash cleanup — DONE

- CS confirmed `feat/prd-052-convert-m2m` is the authoritative home for the drift. Dropped the 2 redundant duplicates (`cs-drift-ondisk`, `cs-drift-prodsync`); kept one backup (`cs-drift-closeout`). Autostash + named-preserve stashes untouched.

## Pending

- **375px / axe QA** on the now-live PRD-059 drawer (orphan/unassigned-expiry section + nearest Exp Qty) — browser step on prod.
- **This docs branch** (`docs/prod-sync-prd058-059-closeout`) needs its own PR to land the status updates on protected `main`.
- **Branch**: `feat/prd-058-059-prod-sync` left in place pending CS confirmation.
