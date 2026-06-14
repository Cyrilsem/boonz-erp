# PRD-030 — Partial Pack state model (Dara design, for Cody review)

**Date:** 2026-06-14 · **Author:** Dara (design) → Cody (review) → assistant (apply on CS go)
**Verified live 2026-06-14** (not re-diagnosed): `pack_dispatch_line` raises on zero/short WH stock; `refill_dispatching` has no `pack_outcome`/`packed_at`/`packed_by`; three FE readiness gates are pure DB counts.

## 0. The dark stage, precisely (3 gates, all count-based)

| Gate                       | File:line                  | Predicate                    | Column      |
| -------------------------- | -------------------------- | ---------------------------- | ----------- |
| Packing-list "Ready" badge | `packing/page.tsx:128`     | `packed_count === sku_count` | `packed`    |
| Driver pickup list         | `pickup/page.tsx:132`      | `packed_count === total`     | `packed`    |
| Driver dispatch list       | `dispatching/page.tsx:110` | `picked_up_count === total`  | `picked_up` |

An OOS line cannot reach `packed=true` (pack RPC raises), so gate 1+2 never hit 100% and the machine is invisible to the driver. Even if forced, an unpacked line is never `picked_up`, so gate 3 also stalls. The fix must make a not-filled line **count as resolved without being packed, picked_up, or WH-debited**.

## 1. The not-filled marker — NEW column, not an overload

- New enum `pack_outcome_enum AS ENUM ('packed','partial','not_filled')`.
- New column `refill_dispatching.pack_outcome pack_outcome_enum NULL` (NULL = pending/unpacked). Set ONLY by `pack_dispatch_line`.
- **Why a new column, not `driver_outcome`:** `driver_outcome` (check: done/partial/not_done/machine_offline/no_stock_on_truck) is the DRIVER's report at the machine, a later lifecycle stage. `pack_outcome` is the WAREHOUSE's result at pack time. Different actors, different stages — overloading would conflate them. Not reusing `skipped` either (skip = operator chose to drop; not_filled = planned, attempted, no stock).
- `filled_quantity` carries the physical truth: `packed` ⇒ `= quantity`; `partial` ⇒ `0 < filled < quantity`; `not_filled` ⇒ `0`. **`quantity` (planned) is always retained** for demand/procurement (today's pack RPC wrongly overwrites it to picked — fixed in §3).

## 2. The two canonical predicates (the heart of the model)

For a `(machine_id, dispatch_date)`, over rows with `cancelled=false`:

- **resolved-for-packing** = `packed=true` OR `skipped=true` OR `include=false` OR `pack_outcome='not_filled'`.
- **physical line** (carries product, needs pickup/dispatch) = `packed=true AND include=true AND cancelled=false` (this naturally excludes not_filled, which stays `packed=false`).

Readiness, computed in ONE canonical view `v_machine_pack_status` (Article 16 — replaces the three ad-hoc client counts):

- `is_pack_complete` = every included non-cancelled line is resolved-for-packing.
- `is_pickup_complete` = every **physical** line is `picked_up`.
- `is_dispatch_complete` = every **physical** line is `dispatched`.

not_filled and skipped lines are resolved-but-non-physical: they never gate pickup or dispatch, and `mark_picked_up` (already `packed=true`-only) ignores them with no change.

## 3. RPC `pack_dispatch_line` (amend — Cody mandatory; signature UNCHANGED)

Keep the exact 3-arg signature `(p_dispatch_id uuid, p_picks jsonb, p_packed_by uuid)` — **no new param** (a 4th arg would create a second overloaded function, the documented foot-gun). The not-filled signal rides in `p_picks`:

- `p_picks = '[]'` (empty array) ⇒ **not_filled**: set `pack_outcome='not_filled'`, `filled_quantity=0`, leave `packed=false`, retain planned `quantity`, **no WH debit, no `from_wh_inventory_id` required**. (Today empty picks raise "must be at least 1", so no caller depends on the old behaviour — safe to repurpose.)
- `0 < SUM(qty) < quantity` ⇒ **partial**: pack the picked units exactly as today (per-batch WH debit, BUG-006 `from_wh_inventory_id` guard intact), but set `pack_outcome='partial'` and **stop overwriting `quantity`** — keep planned so the unfilled remainder is reportable. `filled_quantity` reflects picked.
- `SUM(qty) = quantity` ⇒ **packed**: unchanged behaviour + `pack_outcome='packed'`.
- `SUM(qty) > quantity` ⇒ still raises (over-pick guard kept).

Net diff: (a) early branch for empty picks → not_filled; (b) `pack_outcome` set in each branch; (c) the first-pick `UPDATE ... quantity = v_total_picked` becomes `quantity = v_dispatch.quantity` (retain planned). Everything else (WH debit math, child-row split, provenance GUCs, skipped/cancelled/excluded/already-packed guards) verbatim.

## 4. RPC `confirm_machine_packed(p_machine_name, p_dispatch_date, p_packed_by, p_reason)` (NEW canonical)

- Role gate: warehouse/operator_admin/superadmin/manager. `p_reason` ≥ 10 chars. Sets `app.via_rpc`/`app.rpc_name`.
- Resolve `machine_id`; default `p_dispatch_date` to Asia/Dubai today.
- Compute the per-line state. **If any included, non-cancelled line is unresolved** (not packed, not not_filled, not skipped, include=true) ⇒ return `status='blocked'` + the unresolved lines. It never invents picks (PRD §5.2).
- If all resolved ⇒ upsert one row into NEW table `dispatch_pack_confirmation` (`machine_id, dispatch_date` PK, `confirmed_by`, `confirmed_at`, `reason`, `summary jsonb`) and return `status='ok'` with the per-line summary `{packed, partial, not_filled, skipped}`.
- Writes ONLY the confirmation table (not `refill_dispatching`) ⇒ no `enforce_canonical_dispatch_write` allow-list entry needed. The durable, audited "warehouse said done" signal; `v_machine_pack_status` LEFT JOINs it so the driver app can show "confirmed" distinctly from "coincidentally all-resolved".

### New table `dispatch_pack_confirmation`

Grain = exactly `(machine_id, dispatch_date)` — deliberately NOT on `machines_to_visit` (that is the _planning_ artifact, keyed by `plan_date`; packing is a _dispatch_ artifact and must survive defer/repack to other dates). ENABLE RLS: authenticated SELECT-all, no authenticated write (DEFINER-only via the RPC), audit trigger. Not an Appendix-A protected entity.

## 5. EOD `release_stale_unpacked_dispatches` (amend)

Add `AND COALESCE(pack_outcome::text,'') <> 'not_filled'` to the count + update WHERE so a resolved not-filled line is NOT treated as stale-unpacked (PRD §8: "a packed machine with not-filled lines is complete, not stale"). One-line predicate add; everything else verbatim.

## 6. Fleet reporting `v_not_filled_lines` (NEW view)

Read-only over `refill_dispatching` where `pack_outcome='not_filled'`: `(dispatch_date, machine, shelf, pod/boonz product, planned quantity)`. Feeds procurement and PRD-031. Article 16 canonical object for "unfilled demand".

## 7. Acceptance mapping

1. OOS line packs fully + dispatches → §3 empty-picks not_filled + §2 `is_pack_complete` ignores it + §4 confirm flips machine.
2. not_filled never counted as packed, `filled_quantity=0`, planned retained → §1 (packed=false), §3 (no quantity overwrite).
3. WH never debited for not_filled, BUG-006 intact → §3 (empty-picks branch skips WH; partial/full keep the guard).
4. partial packs available + marks remainder → §3 partial branch (planned retained, `pack_outcome='partial'`; remainder = quantity − filled).
5. not-filled demand reportable by machine+SKU → §6 view.
6. Constitution: single writer per table (`pack_dispatch_line` for lines, `confirm_machine_packed` for the new table), forward-only, no `_v2`, registries updated, Article 16 readiness/reporting via canonical views.

## 8. Battery (runs in §5 step on a rolled-back tx first)

- B1: machine with one zero-stock line → pack the rest, `pack_dispatch_line(line, '[]')` → confirm_machine_packed returns ok → `v_machine_pack_status.is_pack_complete=true`; pickup/dispatch reach 100% over physical lines.
- B2: `pack_dispatch_line(line,'[]')` debits NO `warehouse_inventory` row (snapshot WH before/after; consumer_stock unchanged).
- B3: partial pick (3 of 5) → row `packed=true, pack_outcome='partial', filled_quantity=3, quantity=5`; remainder 2 reportable.
- B4: `v_not_filled_lines` lists the not-filled line(s) for the day with planned qty.
- B5: `release_stale_unpacked_dispatches(dry_run)` does NOT include not_filled lines.

## 9. Resolution of Cody's required items (2026-06-14)

**Required #1 — `conserve_split_dispatch_quantity` interaction (RESOLVED, no trigger change).**
The trigger decrements a packed parent's `quantity` by each packed child's `quantity` to conserve total = sum-of-picks across the multi-batch split. Therefore `quantity` MUST keep meaning "this row's packed units" — repurposing it to "planned" would make a multi-batch partial end at `planned − child_picks`. So the §3 amendment is revised:

- Do NOT change the `quantity = v_total_picked` assignment (conserve stays correct, verbatim).
- Instead snapshot planned into the EXISTING `original_quantity` column: `original_quantity = COALESCE(v_dispatch.original_quantity, v_dispatch.quantity)` on every pack/partial/not_filled write. (`original_quantity` already exists — `edit_dispatch_qty` uses it as the planned snapshot.)
- "planned" for any consumer = `COALESCE(original_quantity, quantity)`; line shortfall = `planned − SUM(filled_quantity over the line's parent+child rows)`.
- not_filled rows never pack (packed=false, no children) so the conserve trigger never fires on them — `quantity` stays planned and `original_quantity` mirrors it.

Net pack_dispatch_line diff shrinks to: (a) empty-picks early branch → not_filled; (b) set `pack_outcome` per branch; (c) set `original_quantity = COALESCE(...)`. The `quantity = v_total_picked` line is UNCHANGED. No `conserve_split_dispatch_quantity` edit, no other trigger touched. `prevent_duplicate_unstarted_dispatch` is satisfied (not_filled is an in-place UPDATE of the single planned row, not a duplicate insert).

**Required #2 — partial remainders in `v_not_filled_lines` (RESOLVED).**
The view aggregates per line `(machine_id, dispatch_date, shelf_id, pod_product_id, boonz_product_id, action)`: `planned = MAX(COALESCE(original_quantity, quantity))`, `filled = SUM(COALESCE(filled_quantity,0))`, `shortfall = planned − filled`, emitted for any line where `bool_or(pack_outcome='not_filled')` OR `(bool_or(pack_outcome='partial') AND shortfall > 0)`, with a `kind` column `full_not_filled | partial_remainder`. Partial shortfalls are now visible to procurement.
