# PRD-031 WS-4 — refill accuracy gate (Dara design, for Cody)

**Date:** 2026-06-14 · Replaces the vacuous stitch deviation block (root-cause D) with a real per-shelf intent-vs-dispatched gate. Article 16 metric + read-only RPC + FE panel. No writes to protected entities.

## 0. Why the old check is vacuous (confirmed live)

The stitch deviation block builds `ex_final` with `variant_target` and `variant_final` as the **identical** expression, so `slot_dev.expected_qty ≡ actual_qty` and the `WHERE expected_qty > actual_qty` insert never fires. `refill_plan_deviations` is structurally always empty for `mapping_gap`. That is exactly why the 2026-06-14 plan dry-ran "0 deviations" while ~40% of intent leaked. WS-4 does not patch that block (left verbatim, forward-only); it adds an independent gate that compares the two things that actually matter: **pod intent vs dispatched SKU total per shelf**, and **dispatched vs shelf gap**.

## 1. The metric (Article 16): "refill execution accuracy"

Canonical object: **`v_refill_accuracy`** (read-only view). One registered metric, one object, all consumers (FE panel + conductor gate RPC) read it. Grain = `(plan_date, machine_id, shelf_id, pod_product_id, action)`.

**Driven from intent, not output.** A shelf-pod that leaked to zero emits **no** `refill_plan_output` row, so the view must drive from `pod_refill_plan` (the intent) and LEFT JOIN the dispatched aggregate — otherwise the worst leaks are invisible. Columns:

- `pod_intent` = `pod_refill_plan.qty` (approved REFILL/ADD_NEW row).
- `dispatched_qty` = `COALESCE(SUM(refill_plan_output.quantity), 0)` over lines matching `(plan_date, machine_name, shelf_code, pod_product_name, action)`. (`refill_plan_output` is name-denormalized; join `pod_refill_plan` → machines.official_name / shelf_configurations.shelf_code / pod_products.pod_product_name, and map action REFILL→'Refill', ADD_NEW→'Add New'.)
- `shelf_current`, `shelf_max`, `shelf_gap = GREATEST(shelf_max - shelf_current, 0)` — from `MAX(refill_plan_output.current_stock/max_stock)` when an output row exists, else from `v_live_shelf_stock` (machine_id + slot_name) and `v_shelf_max_stock` (shelf_id) exactly as stitch computes them, so zero-dispatch shelf-pods still report a gap.
- `wh_short` = `bool_or(comment LIKE '%WH_WARNING%' OR comment LIKE '%WH_STOCK_UNKNOWN%')` over the shelf-pod's output lines.
- `shortfall = GREATEST(pod_intent - dispatched_qty, 0)`.
- `status`:
  - `wh_short` when `shortfall > 0 AND wh_short` (excused — WH genuinely out).
  - `leak` when `shortfall > tol AND NOT wh_short AND shelf_gap > dispatched_qty` (units that should fill remaining shelf room vanished, not a WH problem — the bug WS-2/WS-2b fix; this is the regression tripwire).
  - `over` when `dispatched_qty > pod_intent` (unexpected; over-fan).
  - `ok` otherwise (incl. dispatched < intent because the shelf is already filled to gap — legitimate, not a leak).

`tol` is a small absolute floor (default 1 unit) so largest-remainder rounding never trips the gate.

## 2. The gate RPC: `get_refill_plan_accuracy(p_plan_date date)`

Read-only `SECURITY DEFINER` (operator visibility; no writes), `SET search_path=public`, validates `p_plan_date NOT NULL`. Returns one `jsonb`:

```
{ plan_date, lines:[ {machine_name, shelf_code, pod_product_name, action,
                      pod_intent, dispatched_qty, shelf_gap, wh_short, shortfall, status} ... ],
  summary: { shelf_pods, ok, wh_short, leak, over,
             total_intent, total_dispatched, total_gap,
             intent_fill_ratio  = total_dispatched/NULLIF(total_intent,0),
             gap_fill_ratio     = total_dispatched/NULLIF(total_gap,0),
             verdict: 'pass' | 'flag' | 'block' } }
```

- `verdict='block'` when any `leak` line exists (intent leaked with shelf room and no WH cause).
- `verdict='flag'` when no leak but `gap_fill_ratio < p_min_fill` (default 0.5) — under-fill worth a human look (PRD gate #2); with WS-3 Hybrid (cover-floor) a ratio < 1 is normal, so this is a soft flag, not a block.
- else `pass`.

Signature stays 1-arg (`p_plan_date`); thresholds (`tol`, `p_min_fill`) are body constants to avoid the pg overload foot-gun and keep the FE call trivial. Reads only `v_refill_accuracy`; computes the summary inline over it (that aggregation IS the metric's canonical consumer, not a re-derivation of a different metric).

## 3. Where it runs

- **Post-commit (FE):** `RefillPlanningTab` already calls `stitch_pod_to_boonz(date,false)` at line ~604, then loads `get_refill_plan_output_enriched`. Add a call to `get_refill_plan_accuracy(date)` right after the pending-plan load and render a panel (see §4). This is the human-visible gate "before pushing to drivers".
- **Dry-run (conductor):** the assistant/conductor runs `stitch(date,false)` inside a rolled-back tx on a non-live date (the WS-2 battery pattern), then `get_refill_plan_accuracy(date)` to read the verdict before any real commit. No new dry-run plumbing needed.

## 4. FE (Stax) — `RefillPlanningTab`

After the existing summary strip (~line 1060), a collapsible **Accuracy** panel, shown once a pending plan is loaded:

- A banner: green `pass` / amber `flag (gap fill NN%)` / red `block — N leak line(s)`.
- A table of non-`ok` shelf-pods: machine, shelf, product, intent, dispatched, gap, status badge (`leak` red, `wh_short` amber, `over` grey). `ok` lines collapsed by default.
- Reads `get_refill_plan_accuracy` only (Article 16 — no client re-derivation of intent/dispatched/gap math).

## 5. Battery (rolled-back, non-live date)

- B-leak: synthetic shelf-pod where dispatched < intent with shelf room and no WH warning → `status='leak'`, RPC `verdict='block'`. (Force by inserting a pod row whose mapped variants are all off-shelf on a non-empty shelf — emit 0 while gap>0.)
- B-whshort: dispatched < intent but every output line carries `[WH_WARNING…]` → `status='wh_short'`, not block.
- B-ok: dispatched = intent (or shelf already at gap) → `status='ok'`, `verdict='pass'`.
- B-zero-dispatch visible: a fully-leaked shelf-pod (no output row) still appears with `dispatched_qty=0` (proves intent-driven join).
- B-plan-ratio: `gap_fill_ratio` computed; a deliberately under-filled plan yields `verdict='flag'`.

## 6. Constitution

Article 16 (new canonical metric `v_refill_accuracy`, registered in METRICS_REGISTRY; FE + RPC are its only consumers; inline re-derivation blocked). Article 4 (DEFINER read-only validates input, sets via_rpc not required for a pure reader but harmless). No writes → Articles 1/3/5/6 not engaged. Forward-only (Article 12), no `_v2` (Article 14). The old deviation block is untouched (no destructive edit).
