# Wave-2 Engine Closeout - Execution Log

Goal: `BOONZ BRAIN/GOAL-2026-07-03-wave2-engine-closeout.md`. Run started 2026-07-03 late evening (CS AFK overnight); per the 2026-05-25 precedent, gated blocks were STAGED on branches with Dara/Cody done, nothing prod-facing applied unattended.

## Block 0 - PROD-SYNC (DONE, pushed to main)

Commit `d0b0e26` (chore(prod-sync)): 8 MCP-applied migrations backfilled to git with
byte-equivalent bodies (md5-verified against `supabase_migrations.schema_migrations`),
filenames carry the exact prod registry versions so `db push` skips them:

- `20260702150753_release_stale_wh_pins.sql` (+ pg_cron job 34 recorded, hourly :50)
- `20260702154429_weimi_product_alias_and_phantom_monitor.sql` (table + 20 seed pairs + v_pod_phantom_stock)
- `20260703152341_wh_provenance_enum_add_missing_values.sql`
- `20260615074356_agenda_tracker_boonz_collaborator_flag.sql`
- `20260621094500_prd043_picker_v11_label_bump.sql`
- `20260621100622/100722/100758` capacity audit standard + 2 validator fixes

Findings: prd053a stitch v28 was already recorded locally as `20260624130000_prd053a_stitch_v28_*`
(drifted version, identical SQL body; only header comment differs) - not duplicated.
prd044-047 batch and prd058/059 series verified file-backed on main. Remaining registry
drift is the long-standing version-timestamp drift (265 name-matched pairs) + 27 local-only
orphans - pre-existing convention, out of scope here.

## Block 1 - PRD-044-047 FE (STAGED: branch `feat/wave2-block1-prd044-047-fe`)

Premise correction: qty-edit save wiring and the availability badge ALREADY shipped
(packing page, deploy 37ce14d 2026-06-21). The three genuinely-pending pieces, staged
as 3 commits (tsc + build green):

1. `field/dispatching/page.tsx` - list page now selects the physical subset only
   (`picked_up=true, skipped=false, cancelled=false`); not_filled rows no longer inflate
   totals or render.
2. `field/config/product-mapping/page.tsx` - machine picker filters `status='Active'`.
3. `field/packing/[machineId]/page.tsx` - zero-pick branch routed through
   `pack_dispatch_line` (was a direct `packed=true, filled_quantity=0` table UPDATE;
   Article 3 residue). Zero-qty intent now stamps `pack_outcome='not_filled'` + reason.

## Block 2 - PRD-072 Live Binding (STAGED: branch `feat/wave2-block2-prd072-live-binding`)

**Root cause found (new, urgent):** `confirm_machine_packed` 5-arg (PRD-044 two-mode) was
created WITHOUT argument defaults. The FE's named call `{p_machine_name, p_dispatch_date,
p_reason, p_final}` resolves to NEITHER overload (4-arg lacks p_final; 5-arg's p_packed_by
has no default). Every driver confirm since 06-21 has failed - `dispatch_pack_confirmation`
has 3 rows on 06-21 (ship-day tests), 1 on 06-26, zero since. THIS is the driver-visible
"qty edits not saving": per-line packs succeed, the confirm 404s.

Four migrations, Dara-designed + Cody-reviewed (revisions applied):

- `prd072_p0_bind_fail_reason_columns` - refill_dispatching.bind_fail_reason (CHECK:
  no_stock/quarantined/inactive_batch/pinned_elsewhere) + bind_fail_at + partial index.
- `prd072_p1_pack_dispatch_line_live_rebind` - pre-flight validation of every pick
  (Active, not quarantined, in-date, not pinned elsewhere, stock >= qty) with live FEFO
  re-bind (same predicate as bind_dispatch_fefo); all-or-nothing; fail-soft returns
  status='bind_failed' + machine-readable reason on the line. Dara decision: NO
  reserved_qty column; the pack stops writing the whole-remainder
  reserved_for_machine_id pin entirely (the stock move is the qty-scoped commitment;
  v_dispatch_availability window math covers plan commitments; release_stale_wh_pins
  stays as legacy-pin sweeper).
- `prd072_p2_confirm_retire_legacy_overload` - DROP 4-arg + re-create 5-arg WITH defaults
  (p_final DEFAULT true). Fixes the confirm resolution failure (42725-class, PRD-071
  push v7 precedent).
- `prd072_p3_provenance_registry_guard` - check_provenance_reason_registry() (INVOKER)
  scans all function bodies for set_config('app.provenance_reason', literal) vs the
  wh_provenance_reason_enum constraint + apply-time assert.

Test fixtures: `supabase/tests/prd072_live_binding_fixtures.sql` - scenarios (a)-(e) per
the PRD + 2 golden paths, always-rollback DO block. Run at gate time.
Cody follow-up ticket: pack_dispatch_line has never had an Article-4 role gate (pre-existing;
not changed in this PRD).

## Block 3 - PRD-073 Rec-Driven Splits (STAGED: branch `feat/wave2-block3-prd073-rec-splits`)

Dara scope check: product_mapping already per-machine (machine_id + is_global_default);
no DDL. split_pct and mix_weight stored in sync (mix_weight = pct/100); writer preserves
sync so stitch semantics untouched.

- `prd073_reweight_pod_splits` - canonical writer, p_dry_run DEFAULT true (Gate-1 table
  comes from the same code path), rec flavors scale to 90% proportional, others share 10%
  evenly, 2dp rounding residual onto top rec flavor, post-write sum=100 assert,
  write_audit_log row per call. p_rebuild=true required for broken-sum pods and creates
  recommended-but-unmapped flavors.
- `supabase/tests/prd073_gate1_runner.sql` - seed reweights from the 02-03/07 weekly doc
  (dry-run form). Activia facts verified: WH2-1018-0000-W0 is the sum-170 scope
  (Blueberry 70 + H&O 50 + Straw 50); 'Activia Mix & Go - Greek Yogurt Rasberry' has zero
  mapping rows anywhere. Ambiguous doc rows listed in the runner header for CS to rule on
  at Gate-1 (NOOK Bounty-lean, VW/Zigi even mixes, McVities pod naming, AMZ-1057 Coke,
  AMZ-1038 Loacker vanilla-vs-10%-floor).

## Block 4 - WEIMI alias wiring (STAGED: branch `feat/wave2-block4-weimi-alias-wiring`)

- `weimi_alias_tier_v_live_shelf_stock` - tier-4 'alias' resolution in v_live_shelf_stock
  after direct/case/conventions; rescues only currently-unmatched rows; deterministic
  multi-target pick. Downstream (stitch, engine_add_pod, v_machine_priority,
  v_shelf_sales_identity) inherit via pod_product_id - no further object changes.
  v_machine_service_priority's goods_name join is a SALES-name match, flagged out of scope.

## Block 5 - Close (PENDING gates)

On green lights: apply migrations via MCP (registry-version realign by design), run
fixtures + Gate-1, merge branches to main, deploy, smoke-test, then update CHANGELOG /
MIGRATIONS_REGISTRY / RPC_REGISTRY (reweight_pod_splits, check_provenance_reason_registry,
pack_dispatch_line v-bump, confirm overload retirement) and close this log.

## Gate order proposed to CS

1. Block 2 P2 (confirm defaults fix) - most urgent: driver confirms are broken in prod NOW.
2. Block 1 FE merge + deploy (fast, driver-visible).
3. Block 2 remainder (P0/P1/P3 + fixtures).
4. Block 4 alias tier.
5. Block 3 apply + Gate-1 dry-run table -> CS approves numbers -> Stage-2 writes.
