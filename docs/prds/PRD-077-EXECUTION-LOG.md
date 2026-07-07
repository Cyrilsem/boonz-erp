# PRD-077 Execution Log — Conservation merge gate

Run 2026-07-07, AUTO. Read-only (STABLE fn; no prod planning/inventory write). Engines
byte-identical (fingerprint `c22b57e6…`). Wraps shipped canonical — does NOT fork:
assertion (a) reuses `public.check_pod_conservation`; (b)/(c) use the canonical
`v_wh_pickable` predicate (shared with PRD-079).

## Shipped

- **`refill_qa.conservation_check(plan_date, run_id?, mode)`** → `{status, mode, plan_date,
batch_eval, violations[], totals}`. Classes: `orphan_removal | phantom_batch |
oversubscribed_batch | rounding_leak`. Modes `absolute` / `delta` (excludes signatures
  in the agreed known-debt baseline).
- **`refill_qa.conservation_baseline`** — known-debt store (signature PK, status
  proposed→agreed). Read-only RLS.

## Design decision (logged — reader disambiguation)

The PRD frames batch assertions (b)/(c) as plan-level, but `pod_refill_plan` carries **no
batch reference** at plan time (`preferred_wh_inventory_id` = 0/678 populated 2026-07-07;
binding happens at dispatch via `from_wh_inventory_id`, PRD-036/072). So (b)/(c) evaluate
over `refill_dispatching.from_wh_inventory_id` for the plan_date against `v_wh_pickable` —
the correct locus, using the canonical predicate. Assertion (a) is genuinely plan-level.

## T-tests

| Test                                           | Result                                                                                                                                               |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1 balanced ⇒ pass                             | PASS (synthetic REMOVE 5 = dispatch 5; orphan_removal 0)                                                                                             |
| T2 orphan (plan REMOVE 9 vs dispatch 5) ⇒ fail | PASS — `fail`, orphan_removal 1, class `orphan_removal`                                                                                              |
| T3 empty batch ⇒ phantom_batch                 | PASS — 17 real examples on 2026-07-06 (needed>0, pickable 0)                                                                                         |
| T4 oversubscribed batch ⇒ oversubscribed_batch | PASS — 4 real examples (e.g. needed 12 / pickable 3)                                                                                                 |
| T5 quarantined excluded                        | PASS — inherited from `v_wh_pickable` (excludes quarantined/expired/inactive); such a batch reads pickable 0 ⇒ correctly flagged, never a false pass |
| T6 known-debt baseline                         | RECORDED (proposed) — see below; CS agreement PARKED                                                                                                 |
| T7 prod tables unchanged                       | PASS — STABLE read-only, zero writes                                                                                                                 |

## T6 known-debt baseline (proposed — awaiting CS agreement)

Absolute violations on the two most recent committed plans (as measured 2026-07-07):

- **2026-07-06:** total 21 = phantom_batch 17, oversubscribed_batch 4, orphan_removal 0.
- **2026-07-05:** total 20 = phantom_batch 18, oversubscribed_batch 2, orphan_removal 0.

**Interpretation nuance for CS:** the batch check compares a _past_ plan_date's dispatch
refs against _current_ `v_wh_pickable` (live stock). Past batches already picked/depleted
read pickable 0, so phantom_batch is inflated retrospectively — the batch assertion is
most meaningful at approve-time against contemporaneous stock. This is precisely why the
gate ships with a known-debt baseline + delta mode: the delta gate blocks only NEW
violations vs an agreed reference, so this retrospective debt does not block the wave.
`orphan_removal = 0` on both days confirms plan-balance (a) is clean.

**To agree + freeze the baseline (CS action, not self-approved):**

```sql
INSERT INTO refill_qa.conservation_baseline (signature, captured_for, violation_class, detail, status, agreed_by, agreed_at)
SELECT v->>'signature', '2026-07-06', v->>'class', v->'detail', 'agreed', '<cs_uuid>', now()
FROM jsonb_array_elements((refill_qa.conservation_check('2026-07-06'))->'violations') v
ON CONFLICT (signature) DO NOTHING;
```

Then `conservation_check(<date>, null, 'delta')` blocks only new violations.

## Parked (MASTER-PARKING-LOT)

- T6 baseline **agreement** is a CS decision (which violations are accepted known-debt).
  Gate + proposed set delivered; agreement pending. Pre-seeded park row resolved to
  "artifact delivered, awaiting CS sign-off."

## Status: SHIPPED (gate live, read-only, T1-T5/T7 green). Delta-blocking activates on CS baseline agreement.
