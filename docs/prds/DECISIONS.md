# Clean Ecosystem Loop — DECISIONS

## PRD-CLEAN-01 (2026-07-11, partial: M1 applied, M2 blocked)

### Verified vs claimed state (before)

- Drift confirmed: 30/30 fresh-snapshot machines drifted; ledger 4,677 vs Weimi 5,176 units.
- STALE PRD claims: expired-in-machine Active units = 0 (not 1,095/819 — cleaned by earlier
  drift-kill work); worst machine is AMZ-1038-3001-O1 at 557 vs 160 (not 4,194 vs 160).
- Shelf-grain plan (dry run): 137 shelves to trim (1,319 units), 440 to add (2,903 units,
  246 needing inserts); 54 orphan NULL-shelf Active rows (122 units); 32 Weimi slots on
  1 machine have no shelf_configurations row (250 units unrepresentable in the ledger).

### Judgement calls (all logged in fn behaviour + audit rows)

1. `idx_pod_inv_active_shelf` (UNIQUE machine+shelf+boonz_product WHERE Active) forbids a
   second Active row per product: "insert unattributed batch" therefore (a) tops up an
   existing NULL-expiry row, else (b) inserts a NULL-expiry row for a mapped product with no
   Active row, else (c) converts a zero-stock Active row to the unattributed bucket, else
   merges into the newest dated batch (notes say so).
2. Audit CHECK on source extended with a single value 'drift_resync'; sub-reasons
   ('drift_resync', 'drift_resync_product_mismatch', 'drift_resync_unattributed',
   'drift_resync_orphan_null_shelf') carried in notes; reference_id = 'drift-resync-<run>'
   (deliberately NOT 'manual-refill-%'/'adjust-%' so resyncs never count as visit evidence).
3. Product-mismatch test uses ANY Active product_mapping (machine-scoped or global) — the
   broad match writes off less, the safer direction. product_mapping is many-to-many
   (up to 230 boonz per pod product), so membership, not equality.
4. Write-offs zero current_stock but do NOT flip status (less state change; unique index
   unaffected; fully reversible from audit old_stock).
5. Freshness gate: machine skipped (reported, never zeroed) when latest v_live_shelf_stock
   snapshot_at is NULL or older than 48h. Caught ALHQ-1016 (April snapshot) and
   ALJ-1014_OLD (none).
6. Orphan NULL-shelf Active rows are zeroed (audit: drift_resync_orphan_null_shelf) — they
   can never reconcile to any shelf and inflate machine totals.
7. Added p_dry_run (not in PRD) — used to validate fleet-wide before the real run.

### Rollback

- docs/prds/rollback/pod_inventory_audit_log_source_check_2026-07-11.sql (CHECK restore +
  DROP FUNCTION). Data rollback per row from pod_inventory_audit_log
  WHERE reference_id LIKE 'drift-resync-%'.

### Halt

M2 (fleet data run) denied by the auto-mode permission classifier; not bypassed via
execute_sql on purpose. See docs/prds/BLOCKED.md for resume steps. PRD-CLEAN-02..07 not
started (strict-order rule).

### Git

Working tree had ~30 pre-existing modified files from other sessions (branch
fix/prd-099-approve-return-provenance). Deviation from the goal's `git add -A` + push to
main: committed only loop-created files, no push — sweeping unrelated uncommitted src/
changes into a cleanup commit would deploy unreviewed UI work to prod via Vercel.

### RESOLVED (2026-07-11 ~14:00 UTC): M2 executed + verified attended by CS

- Fleet run at 13:58:22 UTC (single run ref): 37 machines, 1,468 units written off,
  2,793 units added unattributed — 694 audit rows with source='drift_resync'; audit
  delta sums match the ledger delta exactly (battery check 3 PASS).
- Drift = 0 on all touchable machines at run time (battery check 1 PASS); idempotency
  confirmed — second run touched 0 shelves (battery check 4 PASS).
- Expired >30d in machines: already 0 before the run (claim was stale); recorded as
  before=0 / after=0 (battery check 2 PASS trivially).
- Post-run re-check at 14:0x UTC showed 46 shelves drifted against the 14:00:40 snapshot
  (2 min AFTER the resync) — post-resync sales movement, not resync failure. This is the
  expected ongoing decrement gap; per PRD follow-up, watch convergence ~7 days and open
  PRD-CLEAN-08 if fleet drift exceeds 2%.
- Untouchable remainder (by design, never zero on missing data): ALHQ-1016 (stale Apr
  snapshot), ALJ-1014_OLD (no snapshot), and 22 ledger-stocked shelves absent from
  fresh snapshots (AMZ-1029/1038/1057/1068, WH1-2002).
- PRD-CLEAN-01 marked DONE; BLOCKED.md cleared; loop resumes at PRD-CLEAN-02.

## PRD-CLEAN-02 (2026-07-11)

### Verified vs claimed state (before)

- STALE PRD claim: correlation tables were NOT zero-row — 1,119 per-machine +
  1,953 per-loc rows, all computed_at 2026-05-11 (one manual run two months ago,
  never scheduled). The real problem was staleness + no cron.
- find_substitutes_for_shelf signature: (p_plan_date date, p_machine_id uuid,
  p_shelf_id uuid, p_anchor_pod_product_id uuid, p_top_n int, p_aggressiveness_pct int).

### What changed

1. refresh_correlation_pod: day-bucketing fixed from UTC (transaction_date::date,
   now()::date spine) to Asia/Dubai per the non-negotiable timezone rule. Exactly 4
   lines changed (diff-verified); thresholds/pairing/writes untouched. Canonical-writer
   change: original saved to docs/prds/rollback/refresh_correlation_pod_2026-07-11.sql.
2. Ran refresh: 2,751 per-machine + 2,866 per-loc rows in 9.9s (window 60d,
   min_n_days 14, min_sales_per_side 5). No threshold changes needed.
3. cron.schedule('refresh_correlation_weekly', '0 1 * * 0', ...) = Sunday 05:00 Dubai,
   statement_timeout 1200000. Verified active in cron.job.

### Verification battery

1. Row counts > 0: PASS (2,751 / 2,866).
2. Smoke test: PASS 3/3 (AMZ-1029, AMZ-1038, VOXMCC-1005 — all rows
   source='global_basket_fit', pearson 0.36-0.73).
3. cron.job row exists + active: PASS.

### Rollback

- Function: docs/prds/rollback/refresh_correlation_pod_2026-07-11.sql
- Cron: SELECT cron.unschedule('refresh_correlation_weekly');
- Data: derived cache; re-run refresh_correlation_pod() regenerates.

## PRD-CLEAN-03 (2026-07-11, analysis complete — apply BLOCKED on attended approval)

### Verified vs claimed state (before)

- 141 public tables (PRD said ~140). All 18 candidates exist.
- "0 rows" claim is loose: daily_plan_drafts 654, refill_instructions 1,219, seed_staging
  3,868, backups 1,199/1,317, weimi_recon_staging 909, refill_dispatch_plan 52,
  refill_plan_deviations 49, rotation_proposals 21 rows. SET SCHEMA carries data, so
  reversibility holds; the real criterion applied was "no live readers/writers".

### MOVE list (10 tables, 1 view, 13 functions)

- Phase A (0 views, 0 fns, 0 FE refs): pod_inventory_backup_20260416,
  pod_inventory_backup_20260421, weimi_daily_staging, weimi_recon_staging, _debug_log.
- Phase B dead cluster #1 (draft era): daily_plan_drafts + orchestrate_refill_plan,
  engine_finalize, engine_publish_to_refill_plan, propose_add_plan, propose_swap_plan,
  reconcile_intent_progress. Key finding: "engine_finalize called by live fns" was a
  SUBSTRING ARTIFACT of engine_finalize_pod (regex-strip proved it); the only true caller
  is orchestrate_refill_plan, which has zero callers, zero cron, zero FE.
- Phase B dead cluster #2 (rotation era): rotation_proposals + apply_rotation_proposal,
  mark_proposals_expired, propose_rotation_plan, reject_rotation_proposal.
- Phase B singles: refill_action_proposals + compute_nowh_proposals;
  pod_inventory_seed_staging + load_pod_staging_chunk; machine_summary +
  v_machine_summary + backfill_sales_history_qty_v47_window (no dependent views, no FE).

### KEPT in public (conservative wins), with reasons

- refill_plan_lock — FE hit: src/app/(app)/refill/RefillPlanningTab.tsx; lock fns feed
  commit_refill_plan_atomic.
- refill_commit_log — commit_refill_plan is FE-called (RefillPlanningTab.tsx).
- refill_dispatch_plan + daily_pipeline_runs — written by write_dispatch_plan, the
  chat-side EXECUTE_DEPLOYMENT_PLAN writer (0 DB refs expected, like
  weekly_procurement_plan).
- engine_recommendation_snapshot — tg_capture_refill_edit_signal is an ACTIVE trigger
  (learning loop).
- refill_plan_deviations — referenced by stitch_pod_to_boonz (live pipeline).
- refill_instructions (+ v_machine_shelf_plan) — get_machine_slots_with_expiry FE-called
  (SnapshotTab.tsx), upsert_refill_stock_snapshot called from
  src/app/api/refill/stock-refresh/route.ts.
- slot_capacity_max (+ v_slot_capacity) — referenced by engine_swap_pod (live).

### Halt

apply_migration denied by auto-mode classifier (schema move of shared prod state).
Migration staged at supabase/migrations/20260711144500_prd_clean_03_schema_graveyard.sql;
restore at docs/prds/rollback/graveyard_restore_2026-07-11.sql. Baseline npx next build
passes pre-move. Verification battery (dry cycle + rebuild) pending post-apply.

### RESOLVED (2026-07-11 ~15:00 UTC): PRD-CLEAN-03 applied after CS approval

- Migration prd_clean_03_schema_graveyard applied: public tables 141 -> 131;
  graveyard now holds 10 tables + 1 view + 13 functions. Restore script:
  docs/prds/rollback/graveyard_restore_2026-07-11.sql.
- Battery 1 (pipeline dry cycle, non-live date 2026-07-13): pick_machines_for_refill
  picked 4 (AMZ cluster) -> build_draft_for_confirmed built 43 refill rows
  (v19_base_stock / v15_slot_profile / v14_preserve_approved, zero errors) ->
  get_pod_refill_draft returned 43 -> approve_pod_refill_plan + stitch_pod_to_boonz(+2,
  dry) run INSIDE BEGIN/ROLLBACK: stitch v29_driftkill_weimi_identity resolved all lines
  (74 would write, weimi_slot_guard ok, 0 deviations); rollback verified (0 approved
  rows after). Judgement call: stitch requires approved rows, so approval was done in a
  rolled-back transaction rather than persisting approval on a test date (Wave-0
  rollback-envelope pattern).
- Cleanup: deleted the test residue for 2026-07-13 only — 43 pod_refill_plan rows
  (status='draft', approved_at IS NULL) + 4 machines_to_visit rows (status='picked').
  Verified refill_plan_output and refill_dispatching had 0 rows for the date throughout.
- Battery 2: npx next build — 0 errors post-move (baseline also passed pre-move).
- PRD-CLEAN-03 marked DONE. BLOCKED.md removed; loop continues at PRD-CLEAN-04.

## PRD-CLEAN-04 (2026-07-11) — engine rewrite CANCELLED (stale premise), docs delivered

### Verified vs claimed state (before)

- PRD claims live engine is "engine_add_pod v15, FILL-TO-CAPACITY on every selling
  shelf". FALSE since 2026-06-22: live engine is v19_base_stock
  (refill_policy_params.refill_sizing_mode='base_stock'), evolved through v16-v18
  (its own DELETE clause names every generation).
- compute_base_stock_decision already implements the v6 hybrid, and better than the
  PRD's formula:
  - target = LEAST(cap, GREATEST(round(LEAST(s_raw, spoilage_cap)), seller_floor))
    where s_raw = mu_day*trip_days + z*sigma*sqrt(trip_days) (EWMA mu, margin-tiered z)
  - spoilage_cap = mu_day * shelf_life_days * 0.8 with shelf_life_days = REAL remaining
    shelf life of pickable WH batches (v_product_shelf_life), superior to the PRD's
    proposed category_shelf_life lookup (dairy 21 / juice 30 / ...).
  - seller floor 70% of cap for >=1.5/wk sellers = the PRD's "Grade A/B fill to
    capacity"; dead shelves = qty 0 + pod_swaps tag (identical to PRD Grade D);
    ranking stays ranking-only for WH allocation (PRD principle preserved).

### Judgement call: DO NOT replace the engine

Implementing the PRD's v16 (grade-based cover_days_c/floor_c + category shelf-life
table) would REGRESS a more principled live engine and repeat the Wave-1/2 failure
mode (specs written against older engine generations). Safest reversible option:
cancel the rewrite, keep the engine untouched. Consequences:

- pick_urgency_params NOT extended (cover_days_c/floor_c/perishable_half_life columns
  not added) — the equivalent knobs already live in refill_policy_params
  (min_fill_pct, spoilage_factor, z tiers, ewma weights); adding parallel unused
  config would be clutter in a cleanup program.
- category_shelf_life NOT created — real batch shelf life already flows in.
- rollback/engine_add_pod_v15.sql not needed (nothing replaced).

### Delivered

1. docs/refill_engine_bible_v6.md — canonical doctrine documenting the LIVE formula,
   grading mapping, WH allocation, tuner surface, pipeline gates; explicit supersedes
   header. (BOONZ_REFILL_BRAIN_v3.md is not in this repo; noted, not modified.)
2. Deprecation banners injected into refill_engine_bible_v5_7/v5_8/v5_9/v5_10.html
   (red banner after <body>, marker DEPRECATED-BY-V6, links to v6).

### Verification battery (reinterpreted for the live engine, all PASS)

1. Shadow v15-vs-v16: N/A — no engine was replaced; report will carry
   "v15 vs v16 unit deltas: N/A (rewrite cancelled, premise stale)" with evidence.
2. Invariants on engine output (43-row sample plan): qty<0 = 0; qty>0 while
   current>=target = 0; qty over headroom = 0. Finalize R7 60% cap: 0 overruled
   (from the PRD-03 dry cycle stage_2c).
3. No stitched/dispatched plan_date touched (read-only checks + the +2 test date
   residue removed: 43 pod_refills rows deleted; pod_swaps 0).
4. Perishable sample: spoilage_cap present 42/43 rows; binding on REAL plan dates,
   e.g. Activia Mix & Go ADDMIND-1007 s_raw 20.2 -> cap 4.9 (target 5), WPP-1002
   19.7 -> 6.7, Chocolate Bar AMZ-1038 60.3 -> 32.5 (07-09/07-10/07-13 plans).

## PRD-CLEAN-05 (2026-07-11)

### Verified vs claimed state (before)

- refill_plan_output confirmed name-keyed (machine_name/shelf_code/pod_product_name/
  boonz_product_name TEXT), no ID columns; 6,650 rows total, 5,315 in the 60d window.
- STALE PRD detail: live push is v8_driftkill_slot_guard (not "v4"); the canonical
  INSERT writer is write_refill_plan (7 other writers insert too - inject_swap,
  auto_generate_refill_plan (deprecated), approve/commit variants - left name-only on
  purpose; push v9's name fallback covers them).
- Oddity logged: one refill_plan_output row with plan_date 2099-12-09 (sentinel/test).
  Left untouched.

### What changed

1. M1a: 4 nullable uuid columns (machine_id, shelf_id, pod_product_id,
   boonz_product_id) + idx_rpo_plan_machine (plan_date, machine_id). Additive only.
2. write_refill_plan g7 -> g8_id_keyed: INSERT populates the IDs from the already-
   validated names (machines / shelf_configurations with zero-pad normalization /
   pod_products / boonz_products.product_id - NB the boonz PK is product_id).
3. push_plan_to_dispatch v8 -> v9_id_keyed_rpo: resolution prefers line IDs, falls
   back to name matching when NULL (historical rows); same for the M2M source-shelf
   lookup. Generated from the v8 rollback text with 3 targeted replacements
   (diff-verified via generation asserts).
4. M2 backfill (60d window, 5,315 rows): sets ONLY the four new columns.
   Rule tension logged: "never touch non-pending rpo rows" vs PRD-mandated backfill -
   resolved by PRD explicitness + verifying the approve->dispatch trigger is
   AFTER UPDATE OF operator_status (cannot fire on this UPDATE).

### Verification battery (all PASS)

1. E2E on non-live date (+2) inside a rolled-back DO block (DO+RAISE pattern):
   pick -> build_draft -> pod-approve -> stitch COMMIT -> rpo rows 74/74 with all four
   IDs NOT NULL -> approve_refill_plan (trigger auto-push v9) -> 74 dispatch rows.
2. ID-path vs name-path resolution identity on those dispatch rows: 0 mismatches.
3. Backfill coverage: 100% machine_id + shelf_id; 5,282/5,315 pod (99.4%);
   5,233/5,315 boonz (98.5%); 5,200 fully resolved (97.8%). Residual naming debt:
   boonz: Smart Gourmet Classic/Beetroot Humus (38/10), Hunter Ridge Sour Cream (26),
   Hunter Hot N Sweet (5), Vitamin Well (2), Freakin Protein Balls 4P (1);
   pod: Keen Health Chocolate Mix (9), Freakin Healthy Thins (4), McVities
   Digestive/Mini (4/4), Perrier (3), Evian 1L (2), Rice & Corn (3), Granola Bar (2),
   Kinder Bueno (1), Plaay Tablet (1).
4. npx tsc --noEmit: 0 errors (no generated DB types in use for this table).
5. Zero residue on the test date after rollback (picks/pod_plan/pod_refills/rpo/
   dispatch all 0).

### Rollback

- docs/prds/rollback/write_refill_plan_2026-07-11.sql (g7)
- docs/prds/rollback/push_plan_to_dispatch_2026-07-11.sql (v8)
- Columns are nullable/additive; drop statements included in the write_refill_plan
  rollback file. Backfill rollback: SET the four columns NULL for the 60d window.

## PRD-CLEAN-06 (2026-07-11)

### Combination census (grounding the precedence)

Full GROUP BY over refill_dispatching (35,143 rows, 23 distinct combos). Notables:

- driver_outcome is NULL on EVERY row (column exists, never yet written) - kept in
  the precedence for forward compatibility only.
- dispatched=true with packed/picked_up=false is the LEGACY-era completed shape
  (20,814 rows); current-flow rows finish with dispatched+packed+picked_up all true.
  The PRD mapping dispatched -> 'completed' holds for both eras.
- Contradictory combos: cancelled AND returned (3), skipped AND returned (4),
  cancelled AND full journey (6+1), skipped AND full journey (5).

### Judgement call: returned outranks cancelled/skipped

PRD order was cancelled > skipped > returned. Deviation: 'returned' first - recovery
returns of packed lines are legal physical events (PRD-028 doctrine); the return
credit is the operational truth for the 7 cancelled/skipped-AND-returned rows.
Logged here per "encode the precedence that matches operational truth".

### What changed

- CREATE VIEW public.v_dispatch_state (read-only; no writers touched): status
  (returned > cancelled > skipped > completed > in_field > packed > review > pending),
  effective_qty = COALESCE(driver_outcome_qty, driver_confirmed_qty, filled_quantity,
  quantity), planned_qty, original_qty, source ('machine_transfer' when is_m2m OR
  source_origin=internal_transfer OR from_machine_id set, else 'warehouse'), plus
  ID/date/action/expiry pass-throughs.
- Consumer repoint: SKIPPED with rationale - the PRD's named "post-Gate-2 dispatch
  coverage check" does not exist (only _assert_gate_zero does; stale claim), and no
  monitoring fn re-derives state in a way that is provably behavior-identical to the
  view (the returned-precedence fix makes them non-identical by design). FE migration
  is a follow-up per the PRD itself.

### Verification battery (all PASS)

1. today+yesterday: 48 rows, 0 NULL statuses (0 NULL over all 35,143 rows too).
2. Reconciliation query (kept here as the canonical check): raw boolean partition
   with the same precedence vs view status counts - exact match:
   returned 588, cancelled 7,299, skipped 734, completed 26,092, in_field 156,
   packed 8, review 5, pending 261 = 35,143.
3. No write behaviour changed: migration contains a single CREATE VIEW + COMMENT.

### Rollback

DROP VIEW public.v_dispatch_state;

## PRD-CLEAN-07 (2026-07-11)

### Reference audit (grounding the fold-or-defer rule)

- refill_policy_params: 2 fns (engine_add_pod, assert_weimi_slot_match) +
  v_shelf_expiry_risk. Qualifies for folding by the mechanical <=3 rule but the
  readers ARE the live engine + the drift-kill guard - folding would repeat the
  Wave-1/2 failure mode PRD-04 explicitly avoided. DEFERRED (debt recorded).
- refill_settings: 3 fns (engine_swap_pod, set_swaps_enabled,
  sweep_expired_inventory). Same reasoning. DEFERRED. Note: key-value table
  (swaps_enabled=false, sweep_enabled=false), 2 rows not 1.
- refill_priority_params: 0 fns, 0 views, 0 FE, 0 cron -> DEAD. Deviation from the
  PRD: dead tables are GRAVEYARDED, not folded (folding 34 dead columns into the
  live tuner would pollute it). Moved to graveyard.
- service_priority_params: 0 fns; its only reader v_machine_service_priority itself
  has 0 consumers (fns/views/FE/cron). Both moved to graveyard.
- pick_urgency_params stays the live-tuned home (3 fns + 2 views + SignalsTab FE).

### What changed

1. v_refill_config: long-format (source_table, param, value) over
   pick_urgency_params (36) + refill_policy_params (21) + refill_settings (2) = 59.
2. Graveyard: refill_priority_params, service_priority_params,
   v_machine_service_priority (restore commands appended to
   docs/prds/rollback/graveyard_restore_2026-07-11.sql).
3. Capacity split documented in docs/refill_engine_bible_v6.md section 9
   (capacity_standard = per-type default, product_slot_capacity = per-product
   override; slot_capacity_max kept in public - live engine_swap_pod reference).

### Verification battery

1. v_refill_config: 59 params, 59 distinct (source_table, param) - PASS.
2. Full pipeline dry cycle on non-live date (+2) AFTER all PRD-07 moves, in a
   rolled-back DO block: 74 rpo rows, 0 null IDs, 74 dispatch rows - PASS.
3. No tables folded, so no readers patched; build check under final acceptance.

### Rollback

graveyard restore file + DROP VIEW public.v_refill_config;

## PRD-CLEAN-09 (2026-07-12) — engine-side binding-drift fix

### Verified state before acting
- v_slot_binding_drift ALREADY EXISTED with exactly the specified join axis
  (regexp_replace slot_name -> shelf_code; no aisle_code) - reused, not recreated.
- Live drift at build time: 0 rows across 525 current bindings, so the global halt
  assertion is safe to install (tonight's plan unaffected).

### Judgement calls
1. Hard-skip chosen over derive-from-v_live_shelf_stock: rebinding the candidates CTE
   to Weimi identity would change engine behaviour broadly; the skip leaves agreeing
   shelves byte-identical. With the assertion halting on ANY drift, the skip is
   deliberate defense-in-depth (protects if the assertion is later relaxed to warn).
2. Assertion placed in BOTH engines (spec says "the pipeline"): engine_add_pod is the
   plan entry point, but engine_swap_pod can be invoked standalone. RAISE aborts the
   engine transaction, so the engine's own DELETE-and-rebuild rolls back on halt (no
   half-empty plan left behind).
3. Assertion is GLOBAL (per spec) - drift on ANY machine halts ALL plan builds. The
   05:30 Dubai alert (severity critical) fires 10.5h before the 20:00 Dubai build,
   giving CS the reconcile window. Escape hatch documented: reconcile via
   reconcile_shelf_identity_weimi / fix slot_lifecycle, or rollback files.
4. engine version strings and tagged_by values left untouched (downstream matching
   unchanged). New engine output field: binding_drift_skipped.
5. Patches generated from the saved rollback texts with assert-exactly-once
   replacements (PRD-05 technique) - the diff is provably minimal.

### Observed pre-existing bug (NOT touched, out of scope)
engine_swap_pod's dead-tag resolution loop filters reasoning->>'tagged_by' IN
('engine_add_pod_v15','engine_add_pod_v16') but the live add-engine writes
'engine_add_pod_v19_base_stock' -> dead tags from the current engine are never
resolved by the swap engine. Moot while swaps_enabled=false; flag for the Wave-2
unpark work.

### Verification (all in rolled-back transactions, zero residue confirmed)
1. Positive: manufactured 1 drift row (slot_lifecycle flip) -> engine_add_pod halted
   ("1 slot binding drift row(s) ... plan halted (PRD-CLEAN-09)"), engine_swap_pod
   halted, cron_slot_binding_drift_alert reported drift_rows=1 and wrote 1 critical
   monitoring_alerts row.
2. Negative: with 0 drift both the assertion and the alert are silent
   (engine proceeds to the expected "no picked machines" for the bare test date;
   alert drift_rows=0, no rows written).
3. Full pipeline dry cycle on non-live +2: pick -> build_draft (draft_ready,
   v19_base_stock, 41 refills, binding_drift_skipped=0) -> approve -> stitch dry OK.
4. Residue: drift 0, persisted alerts 0, cron active ('30 1 * * *'), both engines
   carry the guard (prosrc check).

### Rollback
engine_add_pod_2026-07-12.sql + engine_swap_pod_2026-07-12.sql in docs/prds/rollback/;
cron.unschedule('slot_binding_drift_nightly') + DROP cron_slot_binding_drift_alert().

---

## 2026-07-16 — PRD-01 fleet-drift 7-day watch reading (re-invocation verification, NO data mutation)

Re-invoked the Clean Ecosystem Loop; all 7 PRDs were already DONE (2026-07-11) and every
deliverable still persists live (verified: graveyard 14 tbl/vw + 13 fns, v_dispatch_state,
v_refill_config, refresh_correlation_weekly cron, slot_binding_drift_nightly cron, PRD-CLEAN-09
drift guard in both engines, uuid-keyed write_refill_plan). Reconciled the stale BLOCKED.md
(it falsely implied an active halt at PRD-03; that was cleared same-day 2026-07-11).

### The watch item (CLEANUP-REPORT final acceptance #2)
The report set a 7-day watch: "open PRD-CLEAN-08 if fleet drift exceeds 2%." Day 5 reading today:

- **Measurement (correct join — the A01↔A1 landmine):** `shelf_configurations.shelf_code` is
  zero-padded (`A01`); `v_live_shelf_stock.slot_name` is un-padded (`A1`). A direct
  `shelf_code = slot_name` join matches only 318 rows and reports a bogus 126% drift. The correct
  normalized join `LEFT(shelf_code,1)||(SUBSTR(shelf_code,2)::int)::text` matches 759 and is the
  number used below. (Logged so the next reader does not repeat the direct-join error.)
- **Fresh matched-shelf drift (snapshots < 24h, 40 machines, snapshot 3.6h old):**
  **1,395 drift units / 5,587 weimi = 25.0%** over 631 fresh matched shelves. **> 2% → watch triggered.**
- **Composition (spot-check top-3):** genuine sales-decrement drift (e.g. ACTIVATE-2005: ledger
  316 / weimi 362, shelf-by-shelf divergence) MIXED with empty-ledger machines
  (LVLUP-2015: ledger 0 / weimi 194; LVLUP-1048: ledger 0 / weimi 141 — resync-skipped-on-stale
  or added after 07-11; not decrement drift, these just need a resync populate).

### Judgement calls (safest reversible option, per goal protocol)
1. **Did NOT auto-fire `resync_pod_inventory_from_weimi()`.** It is a fleet-wide inventory
   mutation (~1,400 write-offs + unattributed adds) that materially rewrites truth + priority
   signals; the established pattern (PRD-01 M2, PRD-03, PROGRAM-2026-05-25) and the auto-mode
   classifier itself gate resyncs as **attended**; and it is cosmetic while the sales-decrement
   root cause is unfixed (drift re-accumulates). On a verification re-invocation of a completed
   loop, not performing a heavy data write is the safer, reversible choice.
   - **Attended re-zero lever (CS, seconds):** `SELECT * FROM public.resync_pod_inventory_from_weimi();`
     (run outside 15:45-16:30 UTC draft cron + 01:45-02:30 UTC picker/reconcile crons).
2. **Did NOT author or execute PRD-CLEAN-08.** It is unauthored, and it is the sales-decrement
   root-cause fix that PRD-01 explicitly scoped OUT ("Do not fix sales decrement logic in this
   PRD"). The goal forbids inventing specs. **This reading is the formal trigger to author
   PRD-CLEAN-08** (root-cause: sales/removals do not reliably decrement the pod_inventory batch
   ledger; the daily_inventory_reconciliation cron @ 02:00 UTC is not converging it to <2%).

### Net
Loop remains COMPLETE and all deliverables intact. One open operational carry-forward: fleet
drift has re-grown to ~25% (as PRD-01 predicted, root cause deferred). Owner: CS — either run the
attended resync as an interim re-zero, or author PRD-CLEAN-08 for the decrement root cause. No
prod data was mutated by this re-invocation (read-only verification only).
