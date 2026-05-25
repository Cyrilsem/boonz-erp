---
id: PRD-015-refill-pipeline
program: PROGRAM-2026-05-25
title: Engine v11.1 follow-ups — shelf_code mismatch, visual_fill, CCZ
status: Drafted-investigation-needed
severity: P2
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 3 P2 #2 (semantic name PRD-007-refill-pipeline)
routing: [Cody]
---

## Source

Per program doc: "Per `project_engine_v11_prd010_deployed`: shelf_code
format mismatch, visual_fill dead code, CCZ signal classification. These
three were flagged at v11 deploy and remain pending."

The memory entry `project_engine_v11_prd010_deployed` is not in the
current memory store, so the exact deploy-time wording can't be quoted.
The three items below are reconstructed from observable code/state and
the program doc summary.

## Item 1 — shelf_code format mismatch

Observed in `auto_generate_refill_plan`:

```sql
CASE
  WHEN aisle_code LIKE '0-A%' THEN 'A'||LPAD(((SUBSTRING(aisle_code,4)::int)+1)::text,2,'0')
  WHEN aisle_code LIKE '1-A%' THEN 'B'||LPAD(((SUBSTRING(aisle_code,4)::int)+1)::text,2,'0')
  ELSE aisle_code
END AS shelf_code
```

And later in `push_plan_to_dispatch`:

```sql
v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
```

Two different normalizations applied in two places. If they ever disagree
on a slot, the dispatch row points to the wrong `shelf_id` (or null on
lookup miss). Likely the cause of "shelf_code mismatch" flagged at deploy.

**Fix sketch:** unify into a single helper function
`public.normalize_shelf_code(text) RETURNS text` and call from both
spots. Forward-only.

## Item 2 — visual_fill dead code

Search the engine codebase for any column named `visual_fill` or
function/view referencing it. If unused, remove.

```sql
-- Investigation query:
SELECT proname FROM pg_proc
WHERE pronamespace='public'::regnamespace AND prosrc ILIKE '%visual_fill%';
SELECT table_name FROM information_schema.views
WHERE table_schema='public' AND view_definition ILIKE '%visual_fill%';
```

If the queries return rows, the term is still live and we have a deeper
investigation. If empty, the cleanup is a column drop on whichever table
holds it (with Cody Article 12 — forward-only with deprecation pre-step).

## Item 3 — CCZ signal classification

CCZ likely refers to a venue classification tier ("Coworking Class Z"?
"Cluster CCZ"?). Need to find where the `signal` column on
`slot_lifecycle` is computed and whether CCZ inputs are mapped correctly.

```sql
-- Investigation:
SELECT proname FROM pg_proc
WHERE pronamespace='public'::regnamespace AND prosrc ILIKE '%ccz%';
SELECT DISTINCT signal FROM slot_lifecycle;
```

If "CCZ" is a tag CS uses for a class of venues, ensure the engine's
tier mapping treats it correctly (currently `auto_generate_refill_plan`
recognizes only KEEP / KEEP GROWING / WATCH / WIND DOWN / ROTATE OUT
signals).

## Why this PRD is "Drafted-investigation-needed"

Without the deploy-time memory entry, each item's exact symptom can't
be specified. Phase 1 of this PRD is the investigation queries above.
Phase 2 ships the fixes.

## Acceptance (placeholder)

- Item 1: single normalize_shelf_code function, both call sites use it,
  smoke test against a known-mismatch slot.
- Item 2: column dropped or removed from codebase if dead; otherwise
  documented as still live.
- Item 3: tier mapping covers all observed signal values.

## Linked

- `auto_generate_refill_plan` source — current engine entrypoint.
