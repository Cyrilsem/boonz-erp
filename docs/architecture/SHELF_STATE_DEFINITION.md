# `v_shelf_state` - definition doc (PRD-110 P1.2 / WS-A1)

Shipped 2026-07-30, migration `20260730160001_prd110_p12_v_shelf_state`.
BUILD SPEC P1.2 requires that this doc **name every source column - no derived guesswork**. It does.

## What it is

The canonical shelf object. **One row per enabled, non-phantom shelf.** Every consumer that needs
"what is on this shelf right now" reads this view and nothing else (G1 = one truth).

**Enabled** := `machines.status = 'Active' AND machines.include_in_refill = true`, and
`shelf_configurations.is_phantom = false`. That is byte-identical to the scope guard inside
`seed_missing_slot_lifecycle` (P0.2), so lifecycle coverage and shelf-state coverage cannot disagree
about who is in scope. Live count on 2026-07-30: **656 rows** (544 with a live WEIMI slot, 112
configured-but-not-live).

The 225 out-of-scope shelves (Active-but-`include_in_refill=false`, incl. LVLUP partner machines, and
the Inactive warehouse pseudo-machines) are deliberately absent - parking-lot **D-02** owns that cohort.

## Column-by-column provenance

| Column                   | Type        | Exact source                                                                                                                      | Notes                                                                                                                                                                                                                                        |
| ------------------------ | ----------- | --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `machine_id`             | uuid        | `shelf_configurations.machine_id`                                                                                                 |                                                                                                                                                                                                                                              |
| `machine_name`           | text        | `machines.official_name`                                                                                                          | label only                                                                                                                                                                                                                                   |
| `operating_model`        | text        | `machines.operating_model`                                                                                                        | **NULL fleet-wide today** - D-07 (backfill apply) is parked. NULL = unclassified, all model rules inert.                                                                                                                                     |
| `shelf_id`               | uuid        | `shelf_configurations.shelf_id`                                                                                                   | the join key for everything downstream                                                                                                                                                                                                       |
| `shelf_code`             | text        | `shelf_configurations.shelf_code`                                                                                                 | canonical zero-padded form (`A01`)                                                                                                                                                                                                           |
| `slot_name`              | text        | `v_shelf_slot_identity.slot_name` (← `v_live_shelf_stock`)                                                                        | WEIMI form (`A1`). Join key to `v_slot_capacity`. NULL when WEIMI has never reported the slot.                                                                                                                                               |
| `pod_product_id`         | uuid        | `v_shelf_slot_identity.pod_product_id`                                                                                            | **WEIMI is the ONLY slot-product identity source.** Never `slot_lifecycle.pod_product_id` (that is the drift side).                                                                                                                          |
| `pod_name`               | text        | `v_shelf_slot_identity.pod_product_name` (← `pod_products.pod_product_name`)                                                      |                                                                                                                                                                                                                                              |
| `pod_shelf_count`        | int         | `count(*) OVER (PARTITION BY machine_id, pod_product_id)` within the view                                                         | replication factor - see "velocity grain" below                                                                                                                                                                                              |
| `sourcing`               | text        | `v_product_sourcing_current.source` aggregated to (machine, pod); falls back to `resolve_product_sourcing_v3(machine, pod, NULL)` | `boonz_wh` / `venue` / `partner` / `mixed` / NULL. See "sourcing grain" below.                                                                                                                                                               |
| `current_stock`          | int         | `v_shelf_slot_identity.current_stock` (← `v_live_shelf_stock`, the registered "Live shelf stock" object)                          | latest WEIMI count                                                                                                                                                                                                                           |
| `max_stock`              | int         | `COALESCE(v_slot_capacity.effective_max_stock, v_shelf_slot_identity.max_stock)`                                                  | **Never** `shelf_configurations.max_capacity` - that column is NULL on all 656 in-scope shelves (measured).                                                                                                                                  |
| `stock_as_of`            | timestamptz | `v_shelf_slot_identity.snapshot_at`                                                                                               | sensor freshness - distinguishes a stale reading from a fresh one                                                                                                                                                                            |
| `velocity_raw`           | numeric     | `slot_lifecycle.velocity_30d`, joined **by `shelf_id` ONLY**                                                                      | units per **DAY** over a 30-day window (measured against `v_shelf_sales_identity.dvel`, ratio 1.00). See "velocity grain".                                                                                                                   |
| `velocity_instock`       | numeric     | **NULL by design until P2.1**                                                                                                     | in-stock-hours velocity. Explicit NULL, never a guess. Fixture 3 seq 15 binds this.                                                                                                                                                          |
| `signal`                 | text        | `slot_lifecycle.signal`                                                                                                           | HERO / KEEP / WIND DOWN / …                                                                                                                                                                                                                  |
| `score`                  | numeric     | `slot_lifecycle.score`                                                                                                            |                                                                                                                                                                                                                                              |
| `composition_confidence` | numeric     | **NULL by design until P1.4**                                                                                                     | estimator confidence. Explicit NULL. Fixture 3 seq 15 binds this.                                                                                                                                                                            |
| `oldest_expiry_est`      | date        | `min(v_machine_expiry_batches.expiration_date)` where `current_stock > 0`, scoped by `shelf_id`                                   | `pod_inventory` is read for **expiry history only** (DATA-SOURCE LAW), through the PRD-105 canonical object.                                                                                                                                 |
| `days_since_verified`    | int         | `CURRENT_DATE - max(evidence_date)` at **shelf** grain                                                                            | evidence = executed dispatch (`refill_dispatching`, not cancelled/skipped, any of picked_up/returned/dispatched/packed) **OR** `pod_inventory_audit_log.reference_id LIKE 'manual-refill-%'`/`'adjust-%'`. NULL = never physically verified. |
| `days_since_visit`       | int         | `v_machine_health_signals.days_since_visit` - **passthrough**                                                                     | machine grain. PRD-074 SSOT (Article 16). NOT re-derived here, and the 365 sentinel/clamp is theirs.                                                                                                                                         |

## Three traps this view makes explicit

### 1. Velocity grain - `velocity_raw` is (machine, pod) grain, REPLICATED across shelves

`slot_lifecycle.velocity_*` is maintained per (machine, pod), not per shelf. 36 (machine, pod) pairs
span 105 shelves today; 34 of them carry an **identical** velocity on every shelf. Worst live case:
one pod on **11** shelves each showing `19.17/day` - summing gives 211/day against a true 19.17/day.

**Never SUM `velocity_raw` across shelves.** `pod_shelf_count` is the replication factor: the naive
per-shelf share is `velocity_raw / pod_shelf_count`, and P2.1 replaces it with a real in-stock split.

### 2. Sourcing grain - the edges are SKU-grain, the shelf is pod-grain

All 4022 `product_sourcing` edges are SKU-grain (`boonz_product_id NOT NULL`); **zero** pod-grain
edges exist. So calling `resolve_product_sourcing_v3(machine, pod, NULL)` alone would return the
operating-model default (`boonz_wh`) for every shelf in the fleet - i.e. a column that looks
populated and is entirely wrong. Measured before shipping; hence the aggregation:

- all SKUs of that (machine, pod) share one source → that source
- they disagree → **`mixed`** (6 shelves / 4 pods today: Chocolate Bar + Soft Drinks Mix on VOX
  co-managed machines, where e.g. Aquafina is venue-supplied and Pepsi is Boonz-supplied)
- no edges at all → the resolver's fallback, whose terminal answer is `boonz_wh` (CONSTRAINED, the
  fail-safe direction - never `venue`)

`mixed` means: **resolve per SKU with `resolve_product_sourcing_v3` before deciding availability.**

Live distribution (2026-07-30): 463 `boonz_wh` · 75 `venue` · 6 `mixed` · 0 `partner` · 112 NULL
(no WEIMI slot). `partner` is 0 because every partner-managed machine is `include_in_refill=false`,
which is exactly what WS-J1 predicts.

### 3. `current_stock IS NULL` means "configured but not live"

112 in-scope shelves have no live WEIMI slot. They are present in the view (coverage is structural)
with NULL stock/pod/sourcing. Consumers that need physically-present shelves filter
`pod_product_id IS NOT NULL`; consumers checking coverage want the NULL rows visible.

## The coverage guarantee

`v_shelf_state` reads `shelf_configurations` directly, so a new shelf appears the instant it is
inserted - coverage cannot regrow a gap. The lifecycle row is the part that needed a guarantee:

`tg_provision_shelf_lifecycle_ins` - AFTER INSERT ON `shelf_configurations`, `WHEN (NOT is_phantom)`
→ `provision_shelf_lifecycle_v3(shelf_id)`, in the same transaction.

Outcomes (all proven by the rollback test in the leg-6 execution log):

| Situation                                | Result                                                                                                                                                                                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| in-scope machine, live WEIMI slot        | `inserted` (or `revived`) - lifecycle row in the same transaction                                                                                                                                                         |
| phantom shelf                            | trigger does not fire at all (WHEN clause)                                                                                                                                                                                |
| machine out of scope                     | `skipped: machine_out_of_scope`                                                                                                                                                                                           |
| shelf already covered                    | `skipped: already_covered` (idempotent)                                                                                                                                                                                   |
| brand-new hardware, WEIMI hasn't seen it | `deferred: no_live_weimi_slot` - **the honest limit**: identity comes from WEIMI, so a slot WEIMI has never reported cannot be bound. The P0.2 nightly coverage cron provisions it on the first snapshot that carries it. |

The insert is never blocked by provisioning: every failure mode returns a JSON reason instead of
raising.

## Consumer migration status (BUILD SPEC P1.2 "ALL consumers migrate")

| Consumer                                             | Status                                                                                       |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| engines (`engine_add_pod`, stitch)                   | **P2** - Family-A freeze (LAW 3). `engine_add_pod_v3` consumes this view; v19 is not edited. |
| `preflight_refill_plan`                              | **P2.6** per BUILD SPEC.                                                                     |
| FE machine page (+ deleting FE's independent scorer) | **Stax ticket, parked** - the view is the prerequisite and it now exists.                    |
| advisory skill                                       | parked with the FE work.                                                                     |

Nothing reads `v_shelf_state` in production yet, by design: LAW 4 (shadow, don't switch). It is the
truth layer the Phase-2 brain is built on.
