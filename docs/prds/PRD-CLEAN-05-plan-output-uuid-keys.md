# PRD-CLEAN-05 — refill_plan_output gets real keys

Status: DONE (2026-07-11) — 4 uuid columns + index added; write_refill_plan g8_id_keyed
populates them; push_plan_to_dispatch v9_id_keyed_rpo prefers IDs with name fallback;
60d backfill 97.8% fully resolved (5,200/5,315). E2E verify in rolled-back txn: 74/74
rows with IDs, dispatch identical (0 ID-vs-name mismatches), tsc 0 errors.
Priority: P2 (fragility fix; additive, non-breaking)

## Problem

refill_plan_output is the only name-keyed table in the canonical path:
machine_name, shelf_code, pod_product_name, boonz_product_name as TEXT.
Every join downstream (dispatch bridge, deviation checks, FE) is a string
match — the single point where naming inconsistencies become operational bugs.

## Design (additive only — FE keeps working untouched)

1. M1 (DDL): ADD COLUMNS machine_id uuid, shelf_id uuid, pod_product_id uuid,
   boonz_product_id uuid (all nullable) + indexes on (plan_date, machine_id).
2. Writer upgrade: `write_refill_plan` (and/or stitch_pod_to_boonz v20 —
   locate the actual INSERT into refill_plan_output and patch THERE) populates
   the four IDs. Names remain as display columns, written from the ID lookups
   (single source: pod_products / boonz_products / machines / shelf_configurations).
3. `push_plan_to_dispatch` (v4): resolve machine/shelf/product via the ID
   columns when present, fall back to name matching when NULL (historical rows).
4. M2 (data): backfill IDs for rows where plan_date >= CURRENT_DATE - 60 via
   name joins; leave older rows NULL. Backfill in a SEPARATE migration from DDL.

## Verification battery

1. Stitch dry-run then commit on a NON-LIVE date: every new refill_plan_output
   row has all four IDs NOT NULL.
2. push_plan_to_dispatch produces identical refill_dispatching rows as before
   (compare on the dry date).
3. Backfill coverage report: % rows resolved for last 60 days (log in
   DECISIONS.md; unresolved = the residual naming debt list).
4. npx tsc --noEmit — 0 errors (types file update if generated types are used).
