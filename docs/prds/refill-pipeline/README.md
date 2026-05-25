# Refill Pipeline PRDs

PRDs derived from the 2026-05-21 refill update doc. Each PRD is self-contained and `/goal`-ready in Claude Code CLI. Solve in priority order.

**Source:** [Refill update 21-05-2026](https://docs.google.com/document/d/1DsREyHeFNSjsjpLuVniAyNzwiVqIKvHvN9_ZZLJBdl4/edit)

## Recommended order

1. **PRD-003** first — phantom WH inventory is the foundational data corruption that downstream symptoms (PRD-001, PRD-008) sit on top of.
2. **PRD-001** next — the M2M misroute is almost certainly one of the contributors to PRD-003 and fixing it stops the bleeding.
3. **PRD-008** — once WH is trustworthy, fix the plan ↔ WH bridge so plans are deliverable.
4. **PRD-002** and **PRD-006** in parallel — the variant story end-to-end (returns + dispatch).
5. **PRD-007** — expiry display.
6. **PRD-004** and **PRD-005** in parallel — engine accuracy tweaks.
7. **PRD-009** last — feature work, not a bug fix; needs the rest of the pipeline trustworthy first.

## Index

| PRD                                                      | Title                                                                              | Severity | Routing                              | Status                |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------- | -------- | ------------------------------------ | --------------------- |
| [PRD-001](./PRD-001-m2m-swap-misroute.md)                | M2M swap misroutes destination machine to warehouse                                | P0       | refill-brain, Cody                   | Done                  |
| [PRD-002](./PRD-002-returns-split-by-variant-ui.md)      | Returns flow blocks splitting and changing product variant                         | P1       | Stax                                 | Done                  |
| [PRD-003](./PRD-003-phantom-mcc-wh-inventory.md)         | Phantom inventory appearing in MCC warehouse                                       | P0       | Dara, Cody                           | Done                  |
| [PRD-004](./PRD-004-engine-fills-full-shelf.md)          | Refill engine recommends adding units to already-full shelves                      | P1       | refill-brain, Dara                   | Done                  |
| [PRD-005](./PRD-005-swap-engine-ignores-better-shelf.md) | Swap engine picks wrong shelf when a better-stocked alternative exists             | P2       | refill-brain                         | Done                  |
| [PRD-006](./PRD-006-dispatch-enforces-single-variant.md) | Dispatch picking enforces a single variant for multi-variant SKUs                  | P1       | Stax, Dara                           | Done                  |
| [PRD-007](./PRD-007-expiry-wrong-in-dispatch.md)         | Expiry dates shown in dispatch don't match warehouse batch reality                 | P1       | Stax, refill-brain                   | Done                  |
| [PRD-008](./PRD-008-refill-plan-shows-phantom-skus.md)   | Refill plan shows phantom SKUs and hides real ones                                 | P1       | refill-brain, Dara                   | Done                  |
| [PRD-009](./PRD-009-driver-feedback-ingest.md)           | Driver on-ground feedback not ingested into refill brain                           | P2       | Dara, Stax, refill-brain             | Done                  |
| [PRD-010](./PRD-010-engine-v11-floor-swap-capacity.md)   | Engine v11 — signal floor + duplicate swap guard + visual fill + capacity warnings | P1       | Dara, Stax, refill-brain, boonz-pico | Done (commit 44ef57a) |
| [PRD-010a](./PRD-010a-swap-guard-shelf-fix-ac4-widen.md) | v9.1 patch — swap guard shelf_code mismatch + AC#4 capacity filter widening        | P1       | Stax, refill-brain                   | Open (Sprint B)       |

## How to use these with Claude Code CLI

These PRDs are written so each one can be picked up with `/goal` independently. Suggested flow:

```
/goal docs/prds/refill-pipeline/PRD-003-phantom-mcc-wh-inventory.md
```

The PRD will give the agent: the problem statement, hypotheses to investigate in order, scope guardrails, acceptance criteria, verification steps, and which advisor agent (Cody / Dara / Stax / refill-brain) must be consulted before merging.

### /plaid pass

These are first-pass drafts. To formalize each one with the `/plaid` Plan capability:

```
/plaid plan docs/prds/refill-pipeline/PRD-003-phantom-mcc-wh-inventory.md
```

This will pressure-test the problem statement, surface hidden constraints, and produce a canonical PRD doc per bug.

## Routing reference

- **Cody** — constitutional review for anything touching protected entities: `machines`, `shelf_configurations`, `planogram`, `sim_cards`, `slots`, `slot_lifecycle`, `pod_inventory`, `warehouse_inventory`, `sales_lines`, `daily_sales`, `settlements`, `refill_plan_output`, append-only logs.
- **Dara** — schema design: tables, columns, types, FKs, indexes, RLS shape, materialized views.
- **Stax** — FE / edge functions / n8n / pg_cron / Vercel.
- **refill-brain** — engine logic in `engine_add_pod` / `engine_swap_pod` / `engine_finalize_pod` / Stitch.

## Status legend

- **Draft** — captured from source doc, not yet pressure-tested
- **Plaid-passed** — formalized via /plaid Plan, ready to schedule
- **In progress** — assigned, /goal kicked off
- **Done** — all acceptance criteria met, verified, merged
