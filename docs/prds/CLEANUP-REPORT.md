# Clean Ecosystem Loop — CLEANUP REPORT (2026-07-11)

All 7 PRDs executed in order. Two required attended approval when the auto-mode
classifier blocked destructive prod writes (PRD-01 M2 data run, PRD-03 apply) —
both were approved and completed. Full per-decision detail: DECISIONS.md.

## Per-PRD summary

| PRD | Result |
|---|---|
| 01 pod-inventory resync | DONE. resync_pod_inventory_from_weimi shipped; fleet run: 37 machines, 1,468 units written off, 2,793 added unattributed (694 audit rows), drift 0 at run time, idempotent. 2 machines + 22 shelves skipped by design (stale/no snapshot — never zero on missing data). |
| 02 correlation revival | DONE. Tables were stale (May 11), not empty. Dubai day-bucketing fix; refresh: 2,751 per-machine + 2,866 per-loc rows; weekly cron (Sun 05:00 Dubai) active; smoke 3/3 machines return global_basket_fit (pearson 0.36–0.73). |
| 03 schema graveyard | DONE. 10 tables + 1 view + 13 functions to graveyard; 7 candidates KEPT (live refs, incl. the engine_finalize substring-artifact catch). Pipeline dry cycle + build pass post-move. |
| 04 refill doctrine v6 | DONE with premise correction: v15 fill-to-capacity engine no longer exists; live v19_base_stock already implements the v6 hybrid (base-stock + seller floor + real-shelf-life spoilage cap). Engine rewrite CANCELLED as regression risk. Delivered bible v6 + deprecation banners + invariant battery (0 violations). |
| 05 plan-output uuid keys | DONE. 4 uuid columns; write_refill_plan g8 populates; push v9 prefers IDs w/ name fallback; 60d backfill 97.8% fully resolved; E2E rolled-back verify: 74/74 rows keyed, dispatch identical (0 ID-vs-name mismatches). |
| 06 dispatch state view | DONE. v_dispatch_state (8 statuses, census-grounded precedence — returned lifted above cancelled/skipped for 7 physical-return rows); 35,143 rows reconcile exactly; no writes changed. Consumer repoint skipped (no Gate-2 check exists; none behavior-identical). |
| 07 config consolidation | DONE. v_refill_config (59 params, 3 tables); 2 dead config tables + 1 dead view graveyarded; policy/settings folds DEFERRED (readers are live engine fns); capacity split documented in bible v6 §9. |

## Before / after metrics

- Ghost units written off: **1,468** (incl. 55 orphan NULL-shelf rows / 122 units);
  **2,793** units added back as unattributed NULL-expiry stock (driver follow-up list).
- Expired-in-machine count: **0 → 0** — the PRD-01 claim of 1,095/819 expired units was
  stale; Active-row expired stock was already cleaned by the earlier drift-kill work.
- Tables: public **141 → 129**; graveyard **0 → 12 tables + 2 views + 13 functions**
  (all SET SCHEMA moves, restore script in docs/prds/rollback/graveyard_restore_2026-07-11.sql).
- Correlation rows: per_machine **1,119 (stale, 2026-05-11) → 2,751 (fresh)**;
  per_loc_type **1,953 → 2,866**; refresh now weekly (cron `refresh_correlation_weekly`).
- v15 vs v16 unit deltas: **N/A** — no engine replacement happened; the live engine is
  v19_base_stock which already supersedes both (see DECISIONS.md PRD-04).

## Final acceptance

1. Pipeline dry cycle on non-live date (+2), after ALL changes: **PASS** — pick 4 →
   draft 43 → approve → stitch commit 74 rpo rows (0 null IDs) → auto-push 74 dispatch
   rows, all inside a rolled-back transaction; zero residue verified.
2. Fleet drift: **0 at resync run time (13:58 UTC), verified**. At 15:31 the fresh
   15:22 snapshot showed 12 machines / 201 units of post-resync sales drift — the
   known decrement gap, not resync failure. Auto-mode blocked an unattended re-run;
   to re-zero on demand (attended): `SELECT * FROM resync_pod_inventory_from_weimi();`
   Watch ~7 days; open PRD-CLEAN-08 if fleet drift exceeds 2% (currently ~3.9% of
   5,100 units after 90 min — mostly the sales-decrement root cause PRD-01 scoped out).
3. Correlation tables populated + weekly cron active: **PASS**.
4. docs/refill_engine_bible_v6.md exists; v5_7–v5_10 carry deprecation banners: **PASS**
   (BOONZ_REFILL_BRAIN_v3.md is not in this repo — noted, untouched).
5. npx next build: **PASS** (0 errors; also passed pre/post graveyard and tsc --noEmit).
6. This report.

## Deferred debt (recorded, deliberate)
- refill_policy_params / refill_settings folds (readers: engine_add_pod,
  engine_swap_pod, assert_weimi_slot_match, set_swaps_enabled, sweep_expired_inventory).
- Naming debt from PRD-05 backfill (115 rows unresolved: Smart Gourmet Humus variants,
  Hunter Ridge Sour Cream, Keen Health Chocolate Mix, etc.) — candidates for
  product_name_conventions / alias entries.
- FE migration to v_dispatch_state (out of scope per PRD-06).
- refill_plan_output sentinel row plan_date=2099-12-09 (left untouched).
- 22 ledger-stocked shelves absent from fresh Weimi snapshots (AMZ x4, WH1-2002) +
  ALHQ-1016 (stale Apr snapshot) + ALJ-1014_OLD — unresolvable until devices report.
