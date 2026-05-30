# PROGRAM-2026-05-30 Phase D — Automation refactor audit

**Captured:** 2026-05-30
**Owner:** Stax (per PRD hard rule 7)
**Trigger:** PROGRAM-2026-05-30-loophole-engine.md Decision A5 + Phase D step 11
**Stop hook:** Phase D requires this audit; the refactor itself is Stax-owned and runs in parallel with the 7-day warning window (2026-05-30 → 2026-06-06).

## Headline

- **FE direct writers to `refill_dispatching`: 13+ call sites across 4 files.**
- Edge functions: 0 direct writers.
- n8n flows: 0 (the `n8n/flows/` directory exists but is empty).
- pg_cron: 0 (no cron command references `refill_dispatching` as raw SQL; the canonical writers are already on the allow-list).

Every FE direct write is now covered by the A.2 enforcement trigger and will emit `bypass_violation_log` rows during the warning window. The volume of those rows is the prioritization signal.

## Per-file inventory (FE)

### `src/app/(app)/refill/DailyDispatchingTab.tsx`

| Line | Pattern                                             | Likely target RPC                                                                                                                                                                                       |
| ---- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 299  | `.from("refill_dispatching").update(updatePayload)` | Depends on `updatePayload` shape. Probably `pack_dispatch_line` or `mark_internal_transfer` if it touches state booleans; could be a bare comment edit which needs a new `update_dispatch_comment` RPC. |

### `src/app/(field)/field/dispatching/[machineId]/page.tsx`

| Line | Pattern                                               | Likely target RPC                                                                                                                                                           |
| ---- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 497  | `.from("refill_dispatching").insert({...})`           | Driver-side Remove insert? Needs investigation; probably wants a new `insert_driver_remove_line` RPC since none of the 11 allow-list writers create driver-initiated lines. |
| 535  | `.delete()` chained off `.from("refill_dispatching")` | `cancel_dispatch_line` if logically a cancel; or new RPC if hard delete.                                                                                                    |
| 624  | `.update({ comment: line.comment.trim() })`           | Comment edit. Add `update_dispatch_comment` RPC.                                                                                                                            |
| 669  | `.update({ comment: line.comment.trim() })`           | Same as 624; consolidate to single canonical writer.                                                                                                                        |

### `src/app/(field)/field/trips/[machineId]/page.tsx`

| Line | Pattern                          | Likely target RPC   |
| ---- | -------------------------------- | ------------------- | -------- | ---------------------------------------------------------------- |
| 228  | `.update({ comment: value.trim() |                     | null })` | Comment edit; same canonical `update_dispatch_comment` as above. |
| 257  | `.update({...})`                 | Depends on payload. |

### `src/app/(field)/field/packing/[machineId]/page.tsx`

| Line | Pattern                                         | Likely target RPC                                                       |
| ---- | ----------------------------------------------- | ----------------------------------------------------------------------- |
| 1142 | `.delete()` chained off refill_dispatching      | `cancel_dispatch_line`.                                                 |
| 1210 | `.update({ packed: true, filled_quantity: 0 })` | `pack_dispatch_line`.                                                   |
| 1268 | `.update({...})`                                | Depends on payload (probably `pack_dispatch_line` with picks).          |
| 1296 | `.update({ include: true })`                    | New canonical `set_dispatch_include` RPC, or fold into an existing one. |

## RPCs that don't yet exist and will likely be needed

1. `update_dispatch_comment(p_dispatch_id uuid, p_comment text)` — multiple FE sites.
2. `set_dispatch_include(p_dispatch_id uuid, p_include boolean)` — packing flow toggle.
3. `insert_driver_remove_line(...)` — if dispatching/page.tsx:497 is a driver-initiated insert (verify intent first).

## Suggested prioritization (Stax)

Order of refactor by traffic + risk:

1. **packing/[machineId]/page.tsx** — drives warehouse packing operations; multi-call file; highest traffic during refill cycles. Refactor first.
2. **dispatching/[machineId]/page.tsx** — drives driver flow; includes the lone INSERT.
3. **trips/[machineId]/page.tsx** — read+comment-edit; lower risk.
4. **DailyDispatchingTab.tsx** — operator UI; single call site.

After 24 hours of warning data, re-rank by actual `bypass_violation_log` counts grouped by `rpc_name IS NULL + actor + occurred_at::date`. That tells Stax exactly which file is firing the most.

## Decision A5 alignment

PRD Decision A5: "Grep `n8n/flows/*.json` + `supabase/functions/**/*.ts` + cron.job for direct INSERT/UPDATE/DELETE on refill_dispatching. Each call site refactored to the canonical RPC. Stax owns this in parallel with the warning-window deploy."

n8n + edge fn + cron surfaces are clean. The FE surface alone needs refactor, and PRD hard rule 7 binds Stax. The backend agent's contribution ends with this audit.

## Cutover risk (2026-06-06)

If any of the 13+ call sites is still firing direct writes on 2026-06-06 when the trigger flips from WARNING to EXCEPTION, **the field PWA flow that uses that site will 500**. Stax + CS must walk through `SELECT DISTINCT rpc_name, COUNT(*) FROM bypass_violation_log GROUP BY rpc_name ORDER BY 2 DESC` on 2026-06-05 morning and confirm count = 0 on rpc_name IS NULL before flipping.

If non-zero on 2026-06-06 morning, defer the flip migration and continue the soak.
