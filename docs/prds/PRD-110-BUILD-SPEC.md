# PRD-110 BUILD SPEC — exact construction detail per phase

Companion to PRD-110-refill-engine-v3-one-brain.md (charter — the WHY/WHAT) and PRD-110-GOLDEN-FIXTURES.md (proof). This file is the HOW. Written for a Claude Code Opus loop; nothing here may be "interpreted creatively" — where detail is missing, the loop asks Dara (design) not its own imagination.

Environment: Supabase `eizcexopcuoycuosittm` (ap-south-1) · admin/operator_admin uuid `82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` · WH_CENTRAL `4bebef68-9e36-4a5c-9c2c-142f8dbdae85` · WH_MCC `4fcfb52c-271f-4aa7-a373-3495e3271cd3` · WH_MM `0aef9ccf-32ad-4545-8413-29bebd931d0b`. All migrations: Dara design → Cody review → apply. All new RPCs suffixed `_v3`. Feature flags in `refill_policy_params` (add columns) or a new `v3_flags` table (Dara call).

---

## PHASE 0 — Live-system fixes (no refactor, ship this week)

### P0.1 Swap-tag repair (RC-06 tags)

`engine_swap_pod` Pass 1 consumes strategic tags filtered by hardcoded source strings `engine_add_pod_v15`/`v16`; `engine_add_pod` now writes `v18`/`v19`. Fix: filter → `source LIKE 'engine_add_pod%'`. One migration, Cody review (SECURITY DEFINER touch).
✔ Verify: on a test plan_date, seed a DEAD tag from v19 output; engine_swap_pod consumes it (pass1_tag_swaps ≥ 1). Fixture 10 unaffected.

### P0.2 slot_lifecycle backfill (~93 invisible shelves)

Target set: `shelf_configurations sc` where `is_phantom=false` AND machine Active/include_in_refill AND shelf has a live WEIMI slot AND no current unarchived slot_lifecycle row. Seed rows: velocity from sales history where present, else category-archetype baseline (`archetype_baseline_velocity` column exists); signal='WATCH'; score neutral; `recommendation_reason='prd110_p0_backfill'`.
⚠ Join by shelf_id ONLY (07-30 lesson). ⚠ Also fix the generator: whatever cron maintains slot_lifecycle must auto-provision on new shelf insert (trigger), else the gap regrows.
✔ Verify: MPMCC-1054-0000-M0, MPMCC-1058-0000-R0, IFLYMCC-1024-0000-W0 each produce ≥10 engine rows on a shadow plan_date (fixture 3). Zero shelves with live stock + no lifecycle row (G2 query returns 0).

### P0.3 Gate 0 — manual activation, first wave (CS decision: NO auto-fallback)

Change `build_draft_for_confirmed`: cron 13 runs `pick_machines_for_refill` and STOPS (status='picked', confirmed_at NULL). Engines (2a/2b/2c chain) run ONLY for machines with confirmed_at set (CS confirm via FE button → `confirm_machines_to_visit`, or `pick_machine_manually` which self-confirms). 8pm advisory must render the "awaiting your confirmation" state with the pick list. NO deadline fallback in wave 1.
✔ Verify: cron run leaves 0 draft rows until confirm; confirm → engines produce draft within one cron cycle or on-demand RPC `build_confirmed_now_v3(plan_date)`.

### P0.4 Fade Fit sentinels (bridge until WS-A2 kills sentinels)

Mint 8 rows: 4 Fade Fit variants × WH_MCC + WH_MM, cloning existing Skittles sentinel shape exactly: warehouse_stock=999, expiration_date='2099-12-31', status='Active', consumer_stock=0, wh_location='VOX_SOURCED', batch_id='VOXSOURCE-<WH>-FADEFIT<n>-999', provenance_reason='manual_adjust'.
✔ Verify: engine run on a VOX shadow date produces Fade Fit qty>0 lines, zero blocked_no_wh for Fade Fit (fixture 5).

### P0.5 blocked_demand ledger (crude v1)

New table `blocked_demand(id, plan_date, machine_id, shelf_id, pod_product_id, boonz_product_id NULL, qty_blocked, reason enum(blocked_no_wh|partial_wh_limited|substitution_exhausted|routing_gap), source enum(engine_add|stitch|pack), created_at, resolved_at NULL, resolution enum(po|spot_buy|transfer|dropped) NULL)`. Writers: engine_add_pod (from its procurement_gaps array — modify function tail to INSERT), stitch (procurement_alerts), FEFO-bind step (unbound rows). Reader: view `v_blocked_demand_open` with aging; weekly-procurement skill updated to read it (skill file edit).
✔ Verify: shadow engine run inserts rows matching its JSON gaps 1:1; 07-30's 20 gaps reproducible.

### P0.6 Data hygiene batch

(a) Map `McVities Digestive - Mini Regular` to pod (CS to name target pod; default: Snack Bar like its siblings). (b) Fix `Vitamin Well - Reload` Union Coop price row 0.4868 → flag `purchase_outcome='price_error'` or correct via edit_purchase_order_line with reason. (c) Merge duplicate supplier `Union Coop (DUP…3cec0b3a)` → 31b6355d (update FKs, mark dup Inactive). (d) INV-06 false positive: preflight INV-06 must treat REMOVE rows as satisfied when a matching Remove line exists in refill_plan_output (join by plan/machine/shelf/pod, action='Remove') — fix the invariant SQL, not the data. (e) Pepsi Black routing: decide with CS — either mint CENTRAL→MCC/MM transfer flow or re-source; interim: document in blocked_demand as routing_gap.

**PHASE 0 GATE:** all six verifies green + fixtures 3, 5, 10 pass + one full nightly cycle (pick → CS confirm → draft → advisory) runs clean in production.

---

## PHASE 1 — Truth layer (WS-A + WS-J1)

### P1.1 `operating_model` (WS-J1)

`machines.operating_model enum('fully_managed','co_managed','partner_managed') NOT NULL` — backfill: venue_group='VOX' → co_managed; LVLUP/LevelUp venue machines → partner_managed; else fully_managed (CS reviews the generated mapping before apply).
`product_sourcing(machine_id, pod_product_id, boonz_product_id NULL, source enum('boonz_wh','venue','partner'), status, valid_from, valid_to, changed_by, reason)` — append-only versioning (new row supersedes, no UPDATE of source). Constraint triggers: partner_managed ⇒ no 'boonz_wh' edges; fully_managed ⇒ no 'venue' edges. Backfill from product_mapping.source_of_supply (venue_team→venue) with the 07-30 lesson: BOTH-rows products resolve to venue on co_managed machines.
FE: product × machine sourcing grid, one-click toggle, audit trail visible (Stax ticket).

### P1.2 `shelf_state` canonical view (WS-A1)

One row per enabled, non-phantom shelf: machine_id, operating_model, shelf_id, shelf_code (canonical A01 form), pod_product_id, pod_name, sourcing (from P1.1), current_stock (latest WEIMI), max_stock, velocity_raw, velocity_instock (P2.1, NULL until then), signal, score, composition_confidence (P1.4, NULL until then), oldest_expiry_est, days_since_verified, last_visit. Definition doc must name every source column — no derived guesswork. ALL consumers migrate: engines (P2+), preflight, FE machine page (Stax — FE's independent scorer DELETED), advisory skill.
Guarantee trigger: shelf_configurations INSERT (non-phantom) ⇒ lifecycle row + shelf_state coverage same transaction.

### P1.3 Sentinel retirement (WS-A2)

With sourcing edges live: planners/stitch/pack read availability = CASE sourcing WHEN 'boonz_wh' THEN real WH stock ELSE unconstrained. Delete VOXSOURCE-* rows AFTER: (a) SOA/settlement regression fixture green (sentinels appear in no revenue math — verify with Cody), (b) 1 week shadow parity.

### P1.4 Inventory events + composition estimator (WS-J2)

`inventory_events(id, ts, machine_id, shelf_id, boonz_product_id, qty_delta, kind enum(load, venue_fill, return, write_off, spot_buy_receive, driver_confirm, correction, derived_decrement, expired_sold_incident), expiry_date NULL, source_ref, actor, note)` — append-only, RPC-only writers.
`shelf_composition(shelf_id, boonz_product_id, est_qty numeric, expiry_bucket, confidence numeric, last_verified_at, updated_at)` — maintained by estimator job each WEIMI snapshot: count drop Δ allocated proportionally across SELLABLE (non-expired) candidates; ⛔ expired buckets immutable to derived decrements (exit only via write_off / return / expired_sold_incident event). Count rise without event: co_managed+venue-sourced ⇒ auto venue_fill event; else anomaly row (`inventory_anomalies`).
Confidence: starts 1.0 at driver_confirm/load-to-empty; decays per unexplained delta + per day; floor visible in FE. Auto-actions gate: expiry auto-write-off lines require confidence ≥ 0.7 (param), else "verify" task.
Driver collapse UI (Stax): flagged shelves only (top uncertainty × value-at-risk, max 3/visit), expected list → confirm / quick-fix; writes driver_confirm events. Photo path stubbed (upload + queue), vision later.
`pod_inventory` → read-only historical after 2-week shadow diff (report daily deltas; cutover on CS approve).
Sales attribution v2: observed mix (composition at sale time) logged per vend for procurement/COGS; static split_pct remains fallback where confidence low.

**PHASE 1 GATE:** shelf_state live + FE on it; G1/G2 queries = 0 violations; sourcing grid editable + audited; estimator shadow diff report running; fixtures 3, 5, 19, 21, 22 green.

---

## PHASE 2 — Demand & quantity brain (WS-B + WS-C) — `engine_add_pod_v3`

- P2.1 velocity_instock: sales ÷ in-stock hours from WEIMI history (shelf empty-hours excluded); stockout-decay guard (old velocity retained when suppression detected — port from weekly-procurement).
- P2.2 Target: S = μ(visit_interval+lead) + z·σ; z from machine_service_policy (join by machine_class); visit_interval from service policy or observed cadence; σ from daily demand variance (min history guard → archetype prior).
- P2.3 Ceiling: min(S, capacity, days_to_expiry_available × sell_rate × safety) — expiry from WH batch (FEFO candidate) at plan time.
- P2.4 Demand multipliers: `demand_calendar(week, machine_class|machine_id NULL, factor, source enum(macro_kpi,event,dow), note)` — loader for CS's existing weekly macro KPI table + context-intelligence events + DOW profile; effective_velocity = velocity_instock × Πfactors (clamped 0.5–2.5).
- P2.5 Unconditional floor (WS-B1): enabled + sourcing≠partner + stock 0 ⇒ line exists (qty from archetype prior if no velocity). Cold-start priors table by category × venue class.
- P2.6 Preflight invariants → blocking at commit (WS-B2) incl. corrected INV-06; coverage_ok required or per-shelf logged exception.
- Runs in SHADOW: writes to `pod_refill_plan_shadow`; nightly diff vs v19 (units, lines, blocked, per-machine) + WMAPE tracking.
  **GATE:** 2 weeks shadow; WMAPE(v3) ≤ WMAPE(v19); fixtures 2, 7, 8, 15 green; CS reviews 3 shadow plans line-by-line.

## PHASE 3 — Optimizer + editing (WS-D + WS-E)

- P3.1 Substitution ladder (WS-D1) in stitch_v3: variant → Pearson substitute (margin-weighted) → alt WH (auto-transfer line) → sibling M2M (overstock donor) → spot_buy_candidate → blocked_demand. Every rung logged in reasoning; silent qty-0 forbidden (assert).
- P3.2 M2M SKU-level (fixture 4): transfers match on boonz_product_id; mixed-SKU source shelves split legs per SKU.
- P3.3 Rotation heartbeat: weekly job → rotation_proposals scored (fit, projected_days_to_sell) → CS gate → approved ⇒ M2M lines next plan.
- P3.4 Facing rightsizing proposals (revenue/facing/day report + proposal queue).
- P3.5 Value-at-risk picker v3: rank = Σ expected lost revenue until next feasible visit; day capacity model (driver-hours, cluster travel, pack time); service-policy cadence floor. Gate 0 UX unchanged (CS selects).
- P3.6 Edits-as-events (WS-E2): `plan_edits(plan_date, shelf_id, pod_product_id, kind, qty, lock enum(hard,soft), author, reason)`; engines compose base plan then apply edit overlay; re-runs NEVER drop overlay; one-verb `swap_v3(machine, shelf, new_product, qty?, cross_machine_source?)` emits correct legs.
- P3.7 One pipeline (WS-E3): dictated path writes plan_edits + engine lines, single approve; conductor path retired.
  **GATE:** 07-30 full replay (fixture 1) green end-to-end incl. 9 edits + re-run preservation (fixture: edit survival); fixtures 4, 6, 11, 12, 13 green.

## PHASE 4 — Feedback, learning, spot-buy, scoreboard (WS-F/G/H/I)

- P4.1 feedback_ledger + proposal generator (pins: perpetual OR N-week, expiry visible; proposals gated). Driver 2-tap (wraps driver_propose_adjustment), client channel via FE form.
- P4.2 `planning_pins(machine, shelf?, product, kind enum(min_facing,protect_depth,always_stock,never_stock), value, mode enum(perpetual,until), expires_at NULL, provenance feedback_ids[])` — L0 reads as constraints.
- P4.3 Edit-history miner (WS-H2) + pick-learning (WS-H4) weekly jobs → proposal queue; acceptance-rate telemetry (G12).
- P4.4 Atomic spot-buy `create_spot_purchase_v3(machine|wh, supplier, lines[{boonz_product_id,qty,price}], receipt_photo)`: one transaction = PO create (auto-number, or addition to today's open walk-in PO) + receive into WH + bind waiting dispatch lines + blocked_demand.resolved='spot_buy'. Live refresh: dispatch board re-evaluates bindings on inventory_events (LISTEN/NOTIFY or short poll). Pre-auth params: class+price cap table (park default: snacks/drinks ≤ AED 15).
- P4.4b **Post-facto fill capture at the machine** (LIVE incident 07-30 01:21, fixture 26): driver fill screen accepts filled ≠ planned with a **source split** — `n from warehouse + m spot-bought` (+ optional flavour breakdown, pod-level accepted when SKUs unknown). WH leg debits only n (guard unchanged — it was right to refuse); spot leg writes a pending spot_fill event + attaches to the open walk-in PO (or creates one) with qty m; PO receive (same night or morning, with receipt expiries) completes the chain: WH in-and-out netted or direct-to-machine receive (Dara call), shelf composition updated to n+m, conservation exact end-to-end. Driver is NEVER stranded on an error message: the error path becomes a guided "record it properly" flow.
- P4.5 Scoreboard: daily materialized metrics — OSA(A-shelves), stockout_rate, waste_pct, WMAPE, plan_adherence, revenue/machine/day, blocked aging, expired_sold incidents, composition confidence avg. FE dashboard (Stax) + weekly Remy review pack.
  **GATE:** fixtures 16, 17, 18, 20, 23 green; scoreboard populated 7 consecutive days; first learned proposal accepted by CS.

## PHASE 5 — Shadow → cutover → autonomy

Per-cluster: v3 shadow beats v19 on scoreboard 2 consecutive weeks → CS cutover approve → flags flip → v19 retained dormant 4 weeks → remove. Autonomy ladder per charter §7 (A1 default; A2 proposal only after 2 clean weeks per cluster; wave-1 Gate 0 stays manual regardless).

## Standing DO-NOT list (from 07-30 and memory — binding on the loop)

Never read stock via product_mapping joins (aggregate warehouse_inventory by product/name). Never read state from pod_inventory (expiry/history only). Never join slot_lifecycle by shelf_code. Never assume sourcing from a single mapping row. Never call a committing RPC twice in one statement. Never regenerate a live/dispatched plan. Never write rpo pre-approved expecting dispatch. Never delete/downgrade; versioned RPCs only. Title Case dispatch actions. A1→A01 zero-pad. Every incident fix ships with its fixture.
