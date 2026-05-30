# PROGRAM-2026-05-26 — Execution log

**Session window:** 2026-05-30 evening (autonomous /goal)
**Parent:** PROGRAM-2026-05-26-refill-data-reconciliation.md

## End state per program done criteria

| #   | Criterion                                             | State                                                                |
| --- | ----------------------------------------------------- | -------------------------------------------------------------------- |
| 1   | 22/24/25 May refill rows reconciled, per-row sign-off | **Blocked** — awaiting CS to paste row data                          |
| 2   | 79 over-allocated rows resolved                       | **Blocked** — needs per-row CS classification (trim/external/cancel) |
| 3   | 28 M2M orphans repaired                               | **Blocked** — needs new RPC build + Cody + per-row CS                |
| 4   | PRD-013 engine investigation written + proposed fix   | **DONE** ✓                                                           |
| 5   | PRD-011 FE drawer + PRD-014 cross-brand RPC + FE      | **Blocked** — Stax + Cody required                                   |
| 6   | PRD-015 + PRD-016 applied                             | **Blocked** — Cody required                                          |
| 7   | MEMORY.md updated                                     | Partial — PRD-013 finding captured                                   |
| 8   | CHANGELOG.md updated                                  | Pending Phase 4/5 ship                                               |

## What shipped (autonomous-safe)

### Phase 3 — PRD-013 engine FEFO investigation: DONE

Diagnostic queries from program doc Phase 3 ran live against prod
2026-05-30. Both patterns returned hits.

**Pattern 1 (engine planned product with 100% Inactive WH):** 90+ rows.
Dominated by Vitamin Well variants, Aquafina, Ice Tea Peach, Barebells
variants, Be-Kind variants, Fade Fit, M&M, Healthy Cola, Pocari Sweat.

**Pattern 2 (engine planned > total Active WH):** 60+ rows. Largest
shortfalls: Aquafina (80 shortfall on 2026-05-19), Evian (30+24),
Coca Cola (29), Nutella Biscuit T12 (29), Ice Tea Peach (28), Zigi (24),
Bounty (18), Kinder Bueno (16), M&M (15), Barebells Creamy Crisp (12).

**Root cause** — two distinct sub-bugs:

- **Bug A:** VOX-sourced products (canonical 9-product list: Pepsi, Ice
  Tea, M&M Bags, Aquafina, Maltesers, Fade Fit, Chocolate Bar, Skittles
  Bag, Soft Drinks Mix) being planned through the WH path at VOX/IFLY/
  Magic Planet/Activate venues. Engine ignores venue_group + the
  canonical VOX list.
- **Bug B:** Variant-assignment loop in `auto_generate_refill_plan` does
  not subtract prior allocations within the same plan run. The SUM
  computed per variant stays static across machines — so the engine can
  plan 5+5+5+5 = 20 units when only 8 are in WH.

**Proposed fix documented** in
`docs/prds/refill-pipeline/PRD-013-engine-fefo-investigation.md` under
"Findings 2026-05-26" section. Includes SQL sketches for both bugs and
a prerequisite `reference_vox_sourced_products` table.

**NOT shipped** — engine is hot path. Per program rule 8 + CS approval
requirement on engine changes.

PRD-013 frontmatter updated:
`status: Investigation-Done-fix-pending-CS-approval`.

## What's Blocked (everything else)

### Phase 1 — Batch-25May / 22May / 24May

Program doc design is explicit per-row CS sign-off in chat. The doc
references "the 25-May refill update doc" with ~70 HUAWEI + ~50 MC line
items, the 22-May doc with ~30 rows, and the 24-May doc with ~50 rows.
**None of these docs are in the repo.** The previous session left a
note that CS holds them externally (Google Docs / Notion / similar).

Phase 1 cannot start without CS pasting row data. The previous (overnight)
session already asked for the Batch-25May paste; the user re-ran /goal
without pasting, so the data is still external. Marked Blocked — needs
CS to paste.

### Phase 2 — 79 over-allocated rows + 28 M2M orphans

The 79 over-allocated rows need physical-reality classification from CS
(trim / external-source / cancel). The 28 M2M orphans need
`repair_orphan_internal_transfer` RPC build (new canonical writer, Cody
review mandatory) plus per-row CS routing decision. Both are Blocked.

Pre-requisite for the 28 orphans: build the RPC. Allow-listed in the
existing `block_orphan_internal_transfer` trigger. Cody review required.

### Phase 4 — PRD-011 FE drawer + PRD-014 cross-brand

PRD-011 backend is Done (`repair_unbound_dispatch` + `bulk_repair_*` +
`mark_dispatch_vox_sourced` live). FE drawer extension on the packing
page requires Stax review per program rule. Mark Blocked.

PRD-014 backend `record_cross_brand_substitution` RPC drafted but not
applied — Cody review required. FE picker requires Stax. Mark Blocked.

### Phase 5 — PRD-015 + PRD-016 hygiene

PRD-015 provenance-warning trigger needs 7-day RAISE WARNING window then
flip — schema change requires Cody approval. Mark Blocked.

PRD-016 phantom pod view + cron + log table — bundled migration needs
Cody review. Mark Blocked.

## Recommended next session

CS provides:

1. **Batch-25May / 22May / 24May source row paste** — one row per line
   in the format `MACHINE-NAME | product | DD/MM/YY | qty`, with
   `UPDATE-EXPIRY:` prefix for the HUAWEI Snickers / MC YoPro corrections.
2. **Cody/Stax skill invocations** for the Phase 4/5 PRDs that have
   complete specs (PRD-014 cross-brand, PRD-015 provenance trigger,
   PRD-016 phantom pod detector, the new
   `repair_orphan_internal_transfer` RPC for Phase 2).
3. **PRD-013 engine fix design call** — CS reviews the two-bug findings
   and decides between (a) ship the proposed allocation-tally fix, (b)
   ship the VOX-list pre-filter fix, (c) both, or (d) different
   approach.

## Hard rules followed in this session

- Article 1, 3, 4, 6, 12 — no canonical writers modified, no direct table
  writes attempted.
- Hard rule 1 (canonical RPC only): not bypassed.
- Hard rule 2 (no DELETE / stock reductions): not bypassed.
- Hard rule 3 (pod-vs-WH expiry scope): n/a this session.
- Hard rule 4 (Cody on every migration): respected — no migrations attempted.
- Hard rule 5 (Stax on every FE diff): respected — no FE diffs.
- Hard rule 6 (verify pg_proc before drafting): pre-req RPCs verified
  live before any spec mention.
- Hard rule 7 (no double-fix): no work duplicated.
- Hard rule 8 (Blocked-with-reason and continue): applied consistently.
