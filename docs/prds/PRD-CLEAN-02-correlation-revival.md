# PRD-CLEAN-02 — Revive the Correlation / Basket-Fit Layer

Status: DONE (2026-07-11) — Dubai day-bucketing fix + refresh (2,751 per-machine /
2,866 per-loc rows, 10s), weekly cron scheduled (Sun 05:00 Dubai, active), smoke test
3/3 machines return source='global_basket_fit' with pearson 0.36–0.73.
Priority: P0 (swap intelligence is silently dead)

## Problem

`correlation_pod_per_machine` and `correlation_pod_per_loc_type` contain ZERO
rows but have ~400k reads. `find_substitutes_for_shelf` COALESCEs the missing
correlation to 0, so every swap-in ranks purely by global velocity: "fleet's
best seller, in stock" on every machine. No basket fit, no location fit.
`refresh_correlation_pod()` exists but is not scheduled and has never
populated the tables.

## Goal

Both correlation tables populated; `find_substitutes_for_shelf` returns
source='global_basket_fit' (non-zero pearson) for machines with sales history;
weekly refresh scheduled.

## Steps

1. Read `pg_get_functiondef` of `refresh_correlation_pod`. Understand its
   source data and thresholds (calibrated Pearson threshold 10 per prior spec).
2. Run it once: `SELECT public.refresh_correlation_pod();`
   (wrap with `SET statement_timeout='1200000'` if heavy).
3. If row counts are still 0: diagnose — likely causes: (a) threshold too high
   for current data volume, (b) reads a stale/renamed source (sales_history
   column drift), (c) writes then deletes. Fix the function (this is a
   canonical-writer change: record before/after definition in DECISIONS.md).
   Timezone rule: any date bucketing MUST use
   `transaction_date AT TIME ZONE 'Asia/Dubai'` first.
4. Schedule weekly: `cron.schedule('refresh_correlation_weekly',
'0 1 * * 0', $$SET statement_timeout='1200000'; SELECT public.refresh_correlation_pod();$$)`
   (Sunday 05:00 Dubai).
5. Smoke test: `SELECT * FROM find_substitutes_for_shelf(...)` on 3 machines
   with ≥30d sales (pick from v_machine_priority). Expect at least some rows
   with pearson_score > 0 and source='global_basket_fit'.

## Verification battery

1. `SELECT COUNT(*) FROM correlation_pod_per_machine;` > 0 and
   `correlation_pod_per_loc_type` > 0.
2. Smoke test above passes on ≥2 of 3 machines.
3. cron.job row exists and active.
