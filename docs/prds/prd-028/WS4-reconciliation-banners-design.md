# PRD-028 WS4 - Reconciliation banner wiring (Stax-style note + CS decision memo)

**Date:** 2026-06-12 · **Status:** CS DECIDED Option 1 + age-split; RPC v2.1 LIVE and cent-equal with the waterfall; consumer ribbon full-scope wiring ticketed to Stax (09a15262) · **Driver:** METRICS_REGISTRY.md row "Payment default / captured / gap"

## What shipped (/app/performance)

ONE call per (period, scope) to `get_payment_default_summary` feeds BOTH the green "PAYMENT DEFAULT" strip and the Transactions-tab dark bar (state `pdSummary`). Scope mirrors the page scope: explicit machine selection -> `p_machine_ids`; else group filter (`All` -> `p_venue_group NULL` = whole non-Inactive/Warehouse fleet). Refunds and Cash are now their own fields on both bars (AC). Client `txnMatchStats` remains ONLY as the table-row model and fallback while the RPC loads. tsc + build green.

Before/after (/app/performance, banner values): Captured switches from client matched-capture (any-status `captured_amount_value` + cash) to canonical `captured_net` (SettledBulk - RefundedBulk + cash); Gap switches from matched-only clamped per-basket gap to canonical `total - captured_net` (includes unmatched refs). Default % switches denominator from matched-total to total_sales.

## CS DECISION NEEDED - consumer ribbons (/refill/consumers + /consumers_vox)

Both pages render ONE component (`ConsumerDashboardClient`), so they are already equal to the cent with each other. Their ribbon is deliberately bound (PRD-023 AC1) to `get_vox_commercial_report.waterfall` so ribbon and Commercial cards "tell one story".

Live comparison, 2026-06-01 -> 2026-06-11, VOX scope:

| metric         | get_payment_default_summary | commercial waterfall |
| -------------- | --------------------------- | -------------------- |
| total_sales    | 13,206.75                   | 13,224.75            |
| captured gross | 10,642.60                   | 10,753.60            |
| refunds        | 213.00                      | 213.00               |
| gap / default  | **2,777.15 / 21.03%**       | **141.30 / 1.27%**   |

The drift is NOT the 3-refs/84-AED scope issue the PRD anticipated - it is semantic: the canonical summary counts 89 UNMATCHED refs (settlement lag / no Adyen record yet) as gap; the waterfall counts only matched-but-short refs. Wiring the partner-facing VOX ribbon to the summary today changes a partner-visible default rate 1.27% -> 21.03% and breaks the PRD-023 ribbon==cards invariant on the same screen (recreating the two-numbers-one-screen disease Article 16 exists to kill).

Options for CS:

1. **Declare matched-only the metric**: change `get_payment_default_summary` to report gap over matched refs (+ separate `unmatched_exposure` field), then wire all ribbons to it (waterfall keeps agreeing). Recommended: keeps partner numbers stable, makes unmatched exposure explicit instead of implicit.
2. **Declare total-exposure the metric**: wire consumer ribbons to the summary as-is and update `get_vox_commercial_report` waterfall to consume the summary (partner sees 21% today; numbers converge but jump).
3. Settlement-lag cutoff variant of 1/2 (only count refs older than N days as default).

Until decided, the consumer ribbons stay on the waterfall (unchanged); /app/performance is internal and now canonical.

## Scope decision (the question the PRD delegated)

`venue_group` (not explicit machine list) for full-scope banners: lists drift as machines onboard; the group + status filter is self-maintaining. Explicit `p_machine_ids` only for user sub-selections (performance page machine picker does this).

## Execution record (2026-06-12)

- Cody: class (d) FE read-only wiring + zero DB changes - fast-path ✅ (Articles 3, 9 n/a: no writes, no edge fn).
- Files: `src/app/(app)/app/performance/page.tsx` (pdSummary state + effect + both bars). The file also carries a few pre-existing Prettier-only reflow hunks from the working tree.
- AC status: performance ribbon == dark bar == canonical RPC by construction (one state object). 3-page equality blocked on the CS decision above. Table-deltas-sum-to-banner-gap holds under option 2 semantics only when the table includes unmatched refs; under option 1 it holds for the matched table as-is - resolve with the same decision.

## CS decision + execution record (2026-06-12, later)

CS: "Option 1 for WS4 with age-split exposure." Shipped as get_payment_default_summary v2 then v2.1 (Cody-approved; signature unchanged, no overload):

- Gap/default over MATCHED refs only; default_pct over matched_total_sales (new field).
- Refund alignment (v2.1): per-ref default_short = GREATEST(total - settled - refunded - cash, 0) - refunds are not default (PRD-023h). Cody's required live comparison caught v2 double-counting a refund-only ref (567.30 vs 141.30; the 426 delta was exactly 2x the 213 refund).
- Age-split exposure: unmatched_refs/unmatched_exposure plus recent (<7d, settlement lag) vs aged (>=7d, likely true default) buckets, age_split_days=7.
- Verification (VOX 2026-06-01..11): gap 141.30 == waterfall 141.30 (cent-equal), default 1.28%, unmatched 93 refs / 2,209.85 AED ALL in the recent bucket, 0 aged - the anticipated settlement-lag story confirmed by data.
- Consumer ribbon wiring: full-scope path -> summary, ticketed to Stax (action_tracker 09a15262); pod subsets stay on the now-agreeing waterfall (summary lacks pod_location scope; signature change deliberately deferred).
