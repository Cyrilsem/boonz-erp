# Wave-2 Engine Closeout - Execution Log (FINAL)

Goal: `BOONZ BRAIN/GOAL-2026-07-03-wave2-engine-closeout.md`, superseded by the v3 AUTO-mode
goal 2026-07-04. Overnight run staged everything on branches (unattended-gate precedent);
the v3 AUTO directive executed the applies/deploys on 2026-07-04. Engine guard held:
`engine_add_pod` md5 `ca074e57…` and `engine_swap_pod` md5 `90f26896…` byte-identical
before and after every block.

## B0 - PROD-SYNC: SHIPPED (bounded+)

Commit `d0b0e26`: 8 MCP-applied migrations backfilled byte-equivalent (md5-verified against
`supabase_migrations.schema_migrations.statements`), filenames carry exact prod registry
versions so `db push` skips them. The 3 goal-named items (release_stale_wh_pins + cron 34,
weimi alias + phantom view, provenance enum fix) plus 5 older unsynced (agenda tracker flag,
prd043 label bump, capacity audit x3). Did NOT copy `BOONZ BRAIN/prod-sync-migrations/`
(its 3 files carry non-registry version stamps; the backfills supersede them).
Sanity PASS: weimi_product_alias count=20; constraint contains dispatch_partial_remainder.
prd053a stitch v28 already recorded locally under a drifted version - not duplicated.
3+6 MIGRATIONS_REGISTRY rows added.

## B1 - PRD-044-047 FE: SHIPPED (merge 168947b, Vercel prod deployed)

Premise correction: qty-edit save wiring + availability/oversubscribed badge ALREADY shipped
2026-06-21 (packing page); the remaining driver symptom was the confirm outage (see B2).
Shipped now:

1. `field/dispatching/page.tsx` - physical subset only (picked_up=true, skipped=false,
   cancelled=false): not_filled rows out of lists and progress counts.
2. `field/config/product-mapping/page.tsx` - machine picker Active-only.
3. `field/packing/[machineId]/page.tsx` - zero-pick branch routed through
   pack_dispatch_line (was a direct packed=true/qty=0 table UPDATE; Article 3 residue).
4. Riders: field-capture + SIM-card pickers Active-only (ALHQ ghost).
   Riders found ALREADY shipped (no action): RefillPlanReview push jsonb toast fix
   (pushResultToToast, on main), PRD-020 Performance tab (branch fully merged).
   DECIDED honored: 033 weimi stays parked.
   Smoke: prod 200; confirm RPC verified end-to-end via PostgREST with the FE arg shape.

## B2 - PRD-072 Live Binding: SHIPPED (4 migrations applied + registry realigned)

**Root cause found and fixed (driver outage):** confirm_machine_packed 5-arg had ZERO
argument defaults, so the FE named call matched neither overload - every driver confirm
failed 06-21..07-04 ("qty edits not saving"; dispatch_pack_confirmation empty since 06-26).
`prd072_p2` drops the 4-arg delegate + re-creates 5-arg with defaults. Verified live.

- `prd072_p0`: bind_fail_reason/bind_fail_at + partial index (Dara: no reserved_qty).
- `prd072_p1`: pack pre-flight + live FEFO re-bind + fail-soft + PIN WRITE DROPPED.
- `prd072_p3`: check_provenance_reason_registry + apply-time assert (first run caught its
  own regex digit gap - m2m_return).
- Fixtures 8/8 PASS on prod (always-rollback; `supabase/tests/prd072_live_binding_fixtures.sql`).
  Prod-guard learnings folded into the fixture file: quarantined + is_global_default are
  GENERATED columns; provenance GUC flip for quarantined rows; one shelf per scenario
  (prevent_duplicate_unstarted_dispatch); PRD-065 auto-credit fires on item_added flip.
- Cody ⚠️→✅ (P3 to INVOKER, applied). Follow-up ticket: pack_dispatch_line has never had
  an Article-4 role gate (pre-existing; unchanged deliberately).

## B3 - PRD-073 Rec-Driven Splits: SHIPPED (RPC + 5 reweights applied; 7 doc rows skipped)

`reweight_pod_splits` applied (dry-run default; p_rebuild for broken sums + creates
recommended-but-unmapped flavors; Active+Warehouse machines; apply-time fixes folded into
the committed file: temp-table DROP-first, is_global_default GENERATED, Warehouse scope).

Applied (current -> proposed, all sums 100, full jsonb in write_audit_log):

| Scope                          | Result                                                                                     |
| ------------------------------ | ------------------------------------------------------------------------------------------ |
| NISSAN Activia                 | Honey 40->45, **Rasberry unmapped->45 (mapping CREATED)**, Strawberries 60->10             |
| WH2-1018 Activia (was sum-170) | Honey 50->45, **Rasberry ->45 (CREATED)**, Blueberry 70->5, Strawberries 50->5             |
| VML-1003 Chocolate Bar         | Bueno 20->45, M&M Nuts 5->25, Twix 5->20, others (Bounty/Galaxy x2/Mars/Snickers) ->2 each |
| VML-1004 Chocolate Bar         | **Oreo ->38.56, Delice ->19.29 (both CREATED)**, Bueno 20->32.14, others ->1.43 each       |
| NISSAN Chocolate Bar           | **Delice ->51.43, Oreo ->38.57 (both CREATED)**, others ->1.25 each                        |

SKIPPED (why):

- OMDCW + ALJLT-O1 Chocolate Bar: KitKat does not exist as a boonz_product at all; honoring
  the rec without its anchor flavor (30-40 weight) distorts the mix. Follow-up: create the
  KitKat product + mapping, rerun from `supabase/tests/prd073_gate1_runner.sql`.
- NISSAN Barebells: doc target "C&C 45" vs sole-rec formula output 90 - needs a CS ruling
  (is 45 a split target or a rec qty?).
- NOOK (Bounty-lean, no quantities), ALJLT-B1/NOOK "VW/Zigi mix N even", Plaay
  milk-choc-heavy, McVities pods (pod-name mapping to 'McVities Digestive Nibbles' rec
  unclear), AMZ-1057 Coke ~5 (needs the pod's full rec set), AMZ-1038 Loacker Vanilla ->0
  (conflicts with the 10%-floor keep-alive principle) - all listed in the runner header.
  Weekly flow hook: runner file is the template; parsed weekly recs call reweight_pod_splits
  (dry-run -> CS Gate-1 -> p_dry_run=false).

## B4 - WEIMI alias wiring: SHIPPED

`weimi_alias_tier_v_live_shelf_stock` applied: tier-4 'alias' after direct/case/conventions
in v_live_shelf_stock (the single name-resolution point; stitch/engine_add_pod/
v_machine_priority/v_shelf_sales_identity inherit via pod_product_id - no other object
changed). Acceptance PASS: 'Freakin Healthy Granola Bar' resolves 7/7; alias tier = exactly
the 17 drifted rows; 2 unmatched remain fleet-wide. v_machine_service_priority's
goods_name join is a SALES-name match - out of scope, reported as designed.

## B5 - Close

MIGRATIONS_REGISTRY (9 rows), RPC_REGISTRY (pack_dispatch_line update, confirm overload
note, reweight_pod_splits + check_provenance_reason_registry rows), CHANGELOG 2026-07-04
entry. Prod registry versions for the 6 new migrations realigned by UPDATE to the committed
filenames. Note: prd073's registry `statements` snapshot predates the 3 in-place function
patches; the committed FILE and the live function are the truth (both match).

## Decisions ledger

- 020 Performance tab: already merged to main (nothing to ship).
- 033 weimi: parked, untouched.
- 053: stitch v28 file already on main under drifted version 20260624130000 (no action).
- Pin model: reserved_for_machine_id write dropped from pack (option 3a); no reserved_qty.

## Follow-ups

1. Create KitKat boonz_product (+ Chocolate Bar mappings) then rerun OMDCW/ALJLT reweights.
2. CS ruling on Barebells C&C 45-vs-90 and the other ambiguous doc rows (runner header).
3. pack_dispatch_line Article-4 role gate (pre-existing gap, Cody-ticketed).
4. Monitor bind_fail_reason rows (idx_rd_bind_fail_open) + rebinds jsonb in pack results
   for the first week; release_stale_wh_pins should trend to 0 pins released.
5. Add check_provenance_reason_registry to the boonz-health skill checklist.
