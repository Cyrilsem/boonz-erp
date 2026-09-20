# PRD-125 — Claude Code prompt

Paste into Claude Code in `boonz-erp`. One session, five phases, stop for CS between
phases 2 and 3.

---

/goal

You are working on the Boonz ERP. Supabase project `eizcexopcuoycuosittm`. Read
`PRD-125-one-path.md` in full first. It has six decisions, D1 to D6. CS has approved them.
This session implements them in the order the PRD gives. Do not reorder.

Rules: `mcp__supabase__apply_migration` for every DDL, one file per phase, named
`prd125_<phase>_<what>`. Never raw DDL via `execute_sql`. Impersonate Cyril operator_admin
`82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` via
`set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true)`
in the SAME `execute_sql` call as any role-gated RPC. `execute_sql` returns only the LAST
statement's output. `product_mapping` joined to `warehouse_inventory` fans out; always
`distinct` on `boonz_product_id`. WEIMI slot codes zero-pad, A1 is A01. WH ids: CENTRAL
`4bebef68-9e36-4a5c-9c2c-142f8dbdae85`, MCC `4fcfb52c-271f-4aa7-a373-3495e3271cd3`, MM
`0aef9ccf-32ad-4545-8413-29bebd931d0b`.

Baselines, captured first and re-run after every phase:

- `validate_refill_plan('2026-09-12', null, 'plan_output')` blocking count
- `validate_refill_plan('2026-09-15', null, 'plan_output')` blocking count
- `select count(*) from refill_dispatching where dispatch_date='2026-09-15'`
- `select p_tier, count(*) from v_machine_priority group by 1`

The 09-15 plan is live and packed. Nothing in this session may change a row on it. Every
proof runs inside a transaction you roll back.

---

## Phase 1 — D2: WEIMI is the shelf truth

Build `public.weimi_shelf_now(p_machine_id uuid)` returning one row per lane from the
latest `weimi_aisle_snapshots` for that machine: `shelf_code` (zero-padded), `pod_product_id`
(resolved through `weimi_product_alias` then `pod_products`), `current_stock`, `max_stock`
with `slot_capacity_max` override applied.

Then, in this order, replace every read of `pod_inventory` that decides placement or
quantity with a read of `weimi_shelf_now`:

1. `push_plan_to_dispatch` Remove path: `shelf_id` is the plan's shelf. The `pod_inventory`
   lot supplies `expiry_date` and `pod_lot_id` only. When no lot exists on that shelf, write
   the row anyway with `expiry_date NULL` and the existing `[EXPIRY-TO-CONFIRM]` comment.
   Delete the `[NO LOT ON SHELF]` zeroing branch entirely.
2. `add_dispatch_row` Remove path: same.
3. The `tg_mark_internal_move_pair` and `is_internal_move_dispatch` logic: an in-machine
   move is detected from the plan's own Remove and Add New on different shelves of one
   machine with the same `boonz_product_id`, not from lots.
4. `v_live_shelf_stock`: sourced from `weimi_shelf_now`.
5. `return_dispatch_line` and `receive_dispatch_line`: the pod archive/credit uses the
   dispatch row's `shelf_id`, never re-resolves it from a lot.

Then `align_pod_lots_to_weimi(p_machine_id uuid, p_dry_run boolean DEFAULT true)`: for each
WEIMI lane, if an Active `pod_inventory` lot exists for that pod product on a different
shelf of the same machine, move the lot to the WEIMI shelf keeping its expiry; if a lane has
stock and no lot anywhere, create one with `expiration_date NULL` and `batch_id
'WEIMI-ALIGN-<date>'`; if a lot exists on a lane WEIMI shows empty or a different product,
set it Inactive with `removal_reason 'weimi_align'`. Report counts. Wire it into the 22:00
cron after the aisle snapshot, dry run false, one machine at a time, with the per-machine
report written to `monitoring_alerts` when it moves or retires more than 5 lots.

**Proof:** rebuild the 09-15 IFLYMCC and MPMCC-1058 engine swaps in a rolled-back
transaction through the real push. Every Remove lands on A08 and A02 with the right quantity
and no manual step. Run `align_pod_lots_to_weimi` dry on all 42 machines and show the
table.

## Phase 2 — D3: stock at the supplying warehouse

Build `public.wh_available_for(p_machine_id uuid, p_boonz_product_id uuid)` returning
`(warehouse_id, free_stock, fefo_expiry)`: if the Active mapping for that product on that
machine (machine-specific first, global second) has `source_of_supply = 'venue_team'`, sum
across WH_MCC and WH_MM; otherwise WH_CENTRAL. Free stock subtracts pins where the dispatch
is not cancelled, skipped, returned, packed or dispatched and `dispatch_date between
current_date and current_date + 30`, nothing else.

Replace the availability read in `engine_add_pod` v15, `find_substitutes_for_shelf` v2,
`validate_refill_plan` G8 and G9, `bind_dispatch_fefo`, and `push_plan_to_dispatch` with
`wh_available_for`. Map `source_origin` to `source_kind` at push: `warehouse` to `wh`,
`vox_at_venue` to `venue`, `internal_transfer` to `m2m`. Backfill the 09-14 and 09-15 rows.

**Proof:** rebuild ACTIVATE-2005 for 09-15 in a rolled-back transaction: zero
`blocked_no_wh` on Aquafina, 137 units planned, all tagged venue. Then
`validate_refill_plan('2026-09-15', null, 'dispatch')` raises no G8 on any venue row.

**STOP HERE. Report phases 1 and 2 with the four baselines. Wait for CS.**

## Phase 3 — D1 and D6: the gate checks the engine's rules

Rewrite `validate_refill_plan` to five blocking checks and nothing else:

- **G3** lane at zero, no line, and no `substitution_rules` match (Phase 4 adds the table;
  until then, no match means no rule)
- **G5** no Active mapping for that `boonz_product_id` on that machine or globally
- **G7** Remove with no Refill or Add New on the same lane in the same plan
- **G8** need exceeds `wh_available_for` free stock
- **G10** a Refill or Add New on a lane where `weimi_shelf_now` shows a different pod
  product and the plan has no Remove for it

Delete G1, G2, G4, G6, G9 from the function. G2, G4 and G9 become boolean columns on
`get_pod_refill_draft` so the FE can show them. Delete the `p_waive` argument from
`approve_refill_plan`, the `refill_plan_gate_waivers` insert, and the waiver table's writers.
Keep the table for history.

Encode D1 in `engine_add_pod`: target = `max_stock` when the lane's 30-day daily velocity is
3 or more, or the product is `venue_team`; otherwise `least(10, max_stock)`. Make the 3 a
row in `refill_policy_params`.

**Proof:** the 09-12 and 09-15 plans re-validated: state the new blocking counts and list
every violation, each must be real. A rolled-back rebuild of AMZ-1038 passes with zero
blocking.

## Phase 4 — D4: substitution rules as data

Table `substitution_rules (rule_id, priority, when_pod_product_id, when_condition text,
then_pod_product_id, then_qty_rule text, never_if_on_machine boolean DEFAULT true,
active boolean, note)`. Seed it with CS's rules from the PRD, D4, exactly as written.

`find_substitutes_for_shelf` reads the table in priority order, checks `wh_available_for`,
checks `weimi_shelf_now` for the "never a product already on another lane" rule, and returns
the first match or nothing. When it returns nothing, `engine_add_pod` leaves the lane at its
current level and writes `no_rule_matched` into `reasoning`. That flag drives the exception
list.

Add the scarce-stock rule: when fleet-wide free stock of a product is under 12, the engine
plans it only on the single highest-velocity lane that wants it.

`get_pod_refill_draft` gains an `exceptions` array: every `no_rule_matched`, every G-check
failure, every lane where WEIMI and `pod_inventory` disagree after alignment.

**Proof:** rebuild 09-15 in a rolled-back transaction with the rules table seeded. Show: the
Evian lanes resolve to Al Ain or Aquafina by site, the Hunter lanes resolve to 9 canisters,
OMDCW A07 resolves to Freakin Roasted from the restocked 7 (not Benlian, since stock exists),
and the exception list is under ten lines.

## Phase 5 — D5: the cron builds every night

Set `gate0_require_manual_confirm = false`. Cron 13 at 20:00 Dubai builds the draft for
`resolve_refill_plan_date()` with `p_repick = true` and writes a `monitoring_alerts` row
with the pick list and the exception count. Retire `refill_draft_missing_alert`.
`approve_pod_refill_plan` becomes the one gate: on success it runs the stitch and the push
inside the same call and returns the dispatch row count. The FE approve button calls it.

**Proof:** run cron 13's command for a rolled-back 09-16 and show the draft, the exception
list, and that no confirm step was needed.

---

## Report

One page per phase. What changed, the proof, the four baselines. If any decision D1 to D6
turned out to conflict with something in the schema you could not resolve, say so and stop
rather than working around it.
