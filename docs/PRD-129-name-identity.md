# PRD-129 — Name and product identity on Machine Health and refill decisions

**Owner:** CS
**Written:** reconstructed 2026-09-22 from migration comments, the rollback snapshot, and
commit `3c47126` (see "A note on this document" at the bottom)
**Status:** CLOSED 2026-09-22 (fresh baseline captured, Cody review complete; see below)

---

## 1. Problem

Three separate places in the Machine Health / refill-decision stack resolved a machine's or a
product's identity by matching on a display name instead of a stable id, and each one had
already drifted from the ground truth by the time this was found:

- `get_machine_health()` reported `machine_name` as `COALESCE(weimi_device_status.device_name,
machines.official_name)`. The default (Active-only) view looked clean only because it hid the
  two rows that had actually drifted: a row labelled `ALJLT-1015-0200-O1` that is really
  `ALJ-1014-0200-O1_OLD`, and one labelled `JET-1016-0000-O1` that is really
  `ALHQ-1016-0000-O1`, both Inactive, both masked rather than fixed. `swap_data` joined
  `planned_swaps` to machines by name for the same reason, when `planned_swaps` already carries
  `machine_id`.
- `v_sales_history_resolved` matched a sale to a `pod_product_id` with a per-row correlated
  subquery (exact name match, then a `product_name_conventions` alias lookup), which is both a
  performance problem (roughly 588ms per resolution when driven per-machine, ~29 seconds for a
  plain `get_machine_health()` call) and the same class of name-matching fragility as the
  machine-name bug above.
- `compute_refill_decision()`'s `v_u7d`/`v_u15d` (7- and 15-day units sold on a lane) were
  computed from a `goods_slot` string transform compared against the shelf's slot name, not by
  product identity. A slot that changed products still counted the previous product's recent
  sales as belonging to the new one.

## 2. Root causes and fixes

**D-011 (machine name identity).** `get_machine_health()` rewritten so `machine_name` is
unconditionally `machines.official_name`; the WEIMI-reported name is kept as its own new column,
`weimi_device_name`, so drift between the two stays visible on the surface instead of silently
overwriting one identity with the other. `swap_data` switched from a name join to a
`machine_id` join. (`20260921125755_prd129_01_name_identity.sql`)

**D-012 (sales resolution identity and performance).** `v_sales_history_resolved` rewritten from
the per-row correlated subquery to a `name_map` CTE (tier 1: exact case-insensitive
`pod_product_name` match) plus an `nm_convention` CTE (tier 2: via
`product_name_conventions.original_name` to `official_name` to `pod_products`, `DISTINCT ON` to
dedupe repeated lowered original names), joined with a `NOT EXISTS` clause that preserves
tier-1-before-tier-2 precedence. Verified equivalent to the old per-row logic on all
`sales_history` rows in the 90 days prior to applying, with zero mismatches, before this was
applied. (`20260921125938_prd129_02a_sales_history_resolved_name_map.sql`) The `dead_stock_count`
and `local_hero_count` subqueries in `get_machine_health()` were additionally scoped to only run
for machines that are Active or have reported to WEIMI in the last 30 days (a no-op at the
default `p_include_inactive=false` scope, since `device_metrics` is already Active-only; it
matters when `p_include_inactive=true` pulls in long-dead machines with no meaningful signal).
Measured after both parts: `get_machine_health()` plain call, default scope, dropped from
29168ms to 2826ms. (`20260921130736_prd129_02b_scope_dead_stock_hero_subqueries.sql`)

**D-013 (decision-layer identity, with a facings correction found during verification).**
`compute_refill_decision()`'s `v_u7d`/`v_u15d` now resolve through `v_sales_history_resolved`
(D-012's set-based rewrite), filtered on the lane's own `pod_product_id`, deleting the
`goods_slot` string-match transform entirely. A first version of this fix
(`20260921131136_prd129_03_decision_identity.sql`, superseded 6 minutes later, never shipped)
summed `v_sales_history_resolved` directly by `pod_product_id` with no facings division —
`v_sales_history_resolved`'s per-product sum is a machine-total, so a product spanning multiple
physical slots (for example Aquafina across 11 slots on `ACTIVATE-2005-0000-W0`) got the same
whole-machine total repeated on every one of its slots, inflating `final_score` by roughly the
facings count. The fix applies the identical facings-division guard `v_shelf_sales_identity`
already uses for the lane-detail table: `v_u7d`/`v_u15d` are the machine-total divided by
`v_facings` (count of the machine's currently live, enabled, non-broken, eligible shelves holding
the same canonical `pod_product_id`), with the `pod_alias` canonicalization
(`168aeb7e-fc0c-441b-94df-6d8cc185945d` to `51e4600f-2c15-428b-92ef-85fdc783c3af`, the old/current
Hunter product pair) applied on both the numerator and the facings count so they agree on
identity the same way `v_shelf_sales_identity` does internally.
(`20260921131742_prd129_03b_decision_identity_facings_fix.sql` is the live definition;
`03_decision_identity.sql` is kept in the migration history as a faithful record of the
superseded, buggy intermediate state and must never be re-applied.)

Scope, confirmed by reading the full function body before writing the fix: `v_u7d`/`v_u15d` feed
only `v_demand_base` (`4 * v_u7d + 0.5 * v_u15d`), which feeds only `v_final` and
`v_local_badge`. `target_units`/`refill_qty` derive from `v_velocity`, itself from
`slot_lifecycle.velocity_7d`/`velocity_30d` — an entirely separate path, untouched by this
change. `final_score` may move; `target_units`/`refill_qty` must not.

**D-014 (regression guard and cron note).** `check_machine_health_integrity()` gets a new
`G-NAME` check comparing `get_machine_health()`'s `machine_name` against `machines.official_name`
in both scopes (default and `p_include_inactive=true`), so a future change cannot quietly
reintroduce the D-011 masking bug. `check_machine_health_integrity()` already takes roughly 3
minutes (`G-LANE-SALES` calls `get_machine_slots_with_expiry()` once per Active machine); per
instruction this was not optimized further here, since the function is documented as a
scheduled-job check, not for interactive use, and G-NAME's added cost (~2.8s) is negligible next
to the existing 3-minute run. (`20260921132825_prd129_04_guard_and_cron_note.sql`)

## 3. Out of scope / not re-verified

`compute_refill_decision()`'s velocity path (`v7`/`v30`, `slot_lifecycle`-derived) was not
touched by this PRD and is not re-verified here.

## 4. Acceptance criteria

| #   | Criterion                                                                                                               |
| --- | ----------------------------------------------------------------------------------------------------------------------- |
| B1  | `get_machine_health.machine_name` comes from `machines.official_name`, with `weimi_device_name` as a separate column    |
| B2  | `v_sales_history_resolved` uses the `name_map` CTE with 0 mismatches on the full sales table                            |
| B3  | `compute_refill_decision` reads `v_u7d`/`v_u15d` by `pod_product_id` with facings normalization and the Hunter alias    |
| B4  | `target_units`/`refill_qty` unchanged on the 663-lane baseline captured 2026-09-21 (0 diff), `final_score` moved on 241 |
| B5  | Guard and cron note in place                                                                                            |

## Verified on 2026-09-22

**B1 — machine_name from official_name, weimi_device_name separate.** Confirmed by reading the
live function body (`pg_get_functiondef`): `device_metrics` selects `m.official_name as
device_name` (which becomes `machine_name` in the final `SELECT`) and `ld.device_name as
weimi_device_name` as a distinct column, `ld` being the `weimi_device_status` join. Live check:

```sql
SELECT count(*) AS gname_violations FROM (
  SELECT g.machine_name FROM get_machine_health() g
  JOIN machines m ON m.machine_id = g.machine_id
  WHERE g.machine_name IS DISTINCT FROM m.official_name
  UNION ALL
  SELECT g.machine_name FROM get_machine_health(true) g
  JOIN machines m ON m.machine_id = g.machine_id
  WHERE g.machine_name IS DISTINCT FROM m.official_name
) x;
```

Result: `gname_violations = 0` in both scopes (this is exactly the live `G-NAME` guard body).
**PASS.**

**B2 — name_map CTE, 0 mismatches on the full sales table.** The live view definition uses the
`name_map`/`nm_convention` CTE shape described above (confirmed via `pg_get_viewdef`). A
full-table comparison against the pre-PRD-129 per-row logic (reconstructed verbatim from
`supabase/rollback/20260921000000_prd129_00_rollback.sql`) timed out on all 51,679
`sales_history` rows — the old logic is a correlated subquery per row, which is the exact
performance problem this PRD fixed, so a full-table run of it is expected to be slow. Ran the
same comparison on the most recent 3,000 rows instead:

```sql
WITH sample AS (SELECT * FROM sales_history ORDER BY transaction_date DESC LIMIT 3000),
old_logic AS (
  SELECT sh.transaction_id,
    COALESCE(( SELECT pp.pod_product_id FROM pod_products pp
               WHERE lower(TRIM(pp.pod_product_name)) = lower(TRIM(sh.pod_product_name)) LIMIT 1),
             ( SELECT pp.pod_product_id FROM product_name_conventions pnc
               JOIN pod_products pp ON lower(TRIM(pp.pod_product_name)) = lower(TRIM(pnc.official_name))
               WHERE lower(TRIM(pnc.original_name)) = lower(TRIM(sh.pod_product_name)) LIMIT 1)) AS pod_product_id_old
  FROM sample sh
)
SELECT count(*) AS total_sampled,
  count(*) FILTER (WHERE ol.pod_product_id_old IS DISTINCT FROM nr.pod_product_id) AS mismatches
FROM old_logic ol JOIN v_sales_history_resolved nr ON nr.transaction_id = ol.transaction_id;
```

Result: `total_sampled = 3000, mismatches = 0`. **PARTIAL PASS** — 0 mismatches confirmed on a
3,000-row recent sample; the full-table claim in the migration's own comment (verified before
applying, at the time) could not be independently re-run today because the pre-change query is
too slow to execute interactively against the live table. Not a failure, but not a full
re-verification either — flagging honestly rather than claiming a full-table check that did not
actually run.

**B3 — facings normalization and Hunter alias.** Confirmed live:

```sql
SELECT (pg_get_functiondef('public.compute_refill_decision(uuid,uuid,uuid,integer)'::regprocedure)
        LIKE '%v_facings%') AS has_facings_fix;
```

Result: `has_facings_fix = true` — the live function is the `03b` version, not the superseded
`03` version. Reading the body confirms `v_u7d`/`v_u15d` are summed from `v_sales_history_resolved`
filtered by `v_pod_canon` (the Hunter-alias-canonicalized `pod_product_id`), then divided by
`v_facings` (count of live/enabled/non-broken/eligible shelves holding that same canonical id).
**PASS.**

**B4 — 663-lane baseline, 0 diff on target/refill, final_score moved on 241.** Could not
verify. Searched for the baseline artifact the migration comment references
(`public._prd129_before_snapshot`):

```sql
SELECT table_name FROM information_schema.tables WHERE table_name ILIKE '%prd129%';
```

Result: no rows. The snapshot table does not exist in the live database — it was evidently a
transient table used during the original session's own verification and was never persisted (no
migration or script in the repo creates or captures it either). **CANNOT VERIFY, and CS has
accepted this** — there is no surviving artifact to diff the 2026-09-21 baseline against, and
reconstructing a "before" state for 663 lanes after the fact is not possible without
re-deriving the pre-facings-fix function, which the repo already flags as "do not apply." This
is a permanent gap in this PRD's own verification record, not something a later session can
close.

To stop this from recurring, a fresh baseline was captured 2026-09-22 for future scoring
changes to diff against: `public._prd129_baseline_20260922` (machine_id, shelf_id,
pod_product_id, boonz_product_id, target_units, refill_qty, final_score, captured_at), built
from every Active machine's current WEIMI-resolved lane via the same
`compute_refill_decision(machine_id, shelf_id, boonz_product_id, 10)` call the engine itself
uses. 660 lanes captured (663 was the 09-21 count; the small drift is expected lane churn, not
an error). This is a persisted table, not a session-local artifact, so it survives this
conversation.

**B5 — guard and cron note in place.** Confirmed:

```sql
SELECT jobid, schedule, command, active FROM cron.job WHERE jobid = 82;
```

Result: `jobid=82, schedule='30 23 * * *', command='SELECT public.run_machine_health_integrity_check();', active=true`.
`check_machine_health_integrity()`'s live body includes the `G-NAME` check block exactly as
described in D-014 (confirmed by `pg_get_functiondef`). **PASS.**

## Cody review — compute_refill_decision step 03/03b (run 2026-09-22)

**Verdict:** Approve with revisions (retroactive review — the change is already live and merged; nothing here is a rollback ask)

**Articles checked:** 4, 12, 16

**Findings:**

- Article 4 not applicable — confirmed live `prosecdef=false, provolatile='s'` (SECURITY INVOKER, STABLE), matching `RPC_REGISTRY.md`'s own entry for this function. No caller-role or write-path concern.
- Article 12 (forward-only migrations) — clean. `03` (the buggy no-facings-division version) is kept in migration history explicitly marked "do not apply," superseded by `03b` six minutes later, never edited in place.
- Article 16 (one canonical object per metric) — **finding, not a block.** `METRICS_REGISTRY.md` registers `v_shelf_sales_identity` as "Sole source of per-(machine,product) shelf velocity... Any future per-product velocity read must use this object, not re-aggregate `sales_history`." `v_u7d` in the 03b fix instead re-aggregates from `v_sales_history_resolved` (itself canonical per D-012) and divides by an independently computed `v_facings`, rather than reading `v_shelf_sales_identity.units_7d` directly (confirmed live: that view already computes `units_7d`/`units_30d` at the exact `(machine_id, canonical pod_product_id)` grain this fix needs, Hunter-alias-canonicalized the same way). `v_u15d` has no existing canonical source at all (`v_shelf_sales_identity` stops at 7d/30d, no 15d window) — re-deriving that one from `v_sales_history_resolved` is not avoidable today, so only `v_u7d` is the duplicate.
- Second, deeper finding surfaced while checking the above: `v_shelf_sales_identity`'s own sales-attribution logic (`sale_resolved` CTE — three separate `pod_products` joins plus `product_name_conventions`) is its own independent name-resolution implementation, written before D-012 and never repointed at `v_sales_history_resolved`. This means two independently-maintained product-identity resolvers for sales now coexist, which is exactly the class of drift D-012 was created to close in the other one. Not part of this PRD's scope to fix, but worth naming rather than leaving implicit.

**Next action:**

- No revert — 03b is correct relative to what it replaced and materially better than not dividing by facings at all.
- Follow-up (not blocking, logged to `docs/BACKLOG.md`): repoint `v_u7d` in `compute_refill_decision` to read `v_shelf_sales_identity.units_7d` instead of re-aggregating `v_sales_history_resolved`, and separately audit whether `v_shelf_sales_identity`'s own sale-resolution CTE should be repointed at `v_sales_history_resolved` now that D-012 exists, to close the two-resolver drift risk.

## A note on this document

This file did not exist anywhere in the repository or its git history when this reconciliation
was written (checked via `git log --all` for the filename and a full-tree search, both empty).
PRD-129 was never given its own branch — its six migrations landed on top of
`prd128-machine-health-fix` in commit `3c47126`, whose message ("fix(prd-129): machine name
identity, sales-resolution perf, decision identity, guards") is the only trace of "PRD-129" in
the git history's subject lines. Two of the six migration files
(`prd129_02a_sales_history_resolved_name_map.sql`, `prd129_03_decision_identity.sql`) carry their
own "REPO HYGIENE RECONSTRUCTION" headers, meaning they were themselves written after the fact
during an earlier reconciliation pass — for `02a`, from the live view definition (faithful,
unmodified since); for `03`, from the exact superseded SQL sent to the migration tool at the
time (deliberately preserved as a buggy intermediate, not the live definition). This document
was reconstructed from those migration comments, the `20260921000000_prd129_00_rollback.sql`
snapshot, and `git show 3c47126`. The 663-lane baseline (B4) is the one claim in the original
scope that could not be reconstructed, because its underlying artifact was never committed to
the repo or persisted in the database. If this reconstruction gets anything wrong relative to
what CS actually meant, the fix is a follow-up revision to this file, not a silent rewrite after
the fact.
