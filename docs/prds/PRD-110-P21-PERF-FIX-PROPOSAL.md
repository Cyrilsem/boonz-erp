# PRD-110 P2.1 — perf fix PROPOSAL for `v_shelf_instock_velocity_v3`

> ## ✅ SUPERSEDED — APPLIED 2026-07-30 (leg 18)
>
> This proposal was executed. A1, A2 and A3 all passed, Cody approved (Art 2/3/12/14/16), and the
> fix shipped as **`20260730170009_prd110_p21_velocity_v3_perf_single_flatten`** (file on disk).
> The `_test` shadow was dropped. **The document below is kept as the reasoning record only** —
> the authoritative artifact is the migration file. Section 5 (materialized-view escalation) was
> NOT needed: the plain view is fast enough to query fleet-wide in one statement.
>
> Still open: the view has never been checked against `PRD-110-P21-ORACLE.json`.

**Status (original): DRAFTED, NOT APPLIED, NOT TESTED.** Written in leg 18 while the database was
unreachable. This is deliberately **not** a file in `supabase/migrations/` — an unapplied
migration file there would be picked up by `supabase db push` and would break the RELAY
handoff invariant ("disk and DB agree"). Leg 19 promotes this to a real migration **only
after** the pre-flight assertions below pass.

Derived from the two on-disk applied artifacts (`20260730170001`, `20260730170002`), not
from memory and not from a live plan — **no `EXPLAIN` has ever been run on this view.**

---

## 1. Diagnosis — why it saturated prod

`v_weimi_shelf_history_v3` is expensive per evaluation: a triple `LATERAL
jsonb_array_elements` flatten of `weimi_device_status.door_statuses` (→ 79,094 rows over
full history, **no date filter inside the view**), then **four** `LEFT JOIN LATERAL`
resolver lookups per flattened row, then a `DISTINCT ON` sort over all of it.

`v_shelf_instock_velocity_v3` references that view **four times**:

| #   | site                                         | line (170002) | why it's avoidable                                  |
| --- | -------------------------------------------- | ------------- | --------------------------------------------------- |
| 1   | `w.t_anchor` — `max(snapshot_at)`            | 32            | needs only a max over a base column                 |
| 2   | `w.t_start` — `max(snapshot_at)` **again**   | 33            | same scalar, computed twice                         |
| 3   | `hist`                                       | 45            | **genuinely needs** the flatten + resolved identity |
| 4   | `snaps` — `DISTINCT machine_id, snapshot_at` | 54            | needs no flatten at all                             |

**The compounding defect:** `w` derives the window bounds _from the view itself_. That
circular dependency means the planner cannot treat `t_start`/`t_anchor` as constants, so the
30-day predicate in `hist`/`snaps` **cannot push down** — every evaluation materialises full
history before filtering. Four full flattens per query.

The incident query then multiplied this by ~10 independent aggregates in one statement.
4 × 10 = ~40 full flattens. That is the incident.

## 2. The fix — 4 evaluations → 1, and make the window a constant

Two changes, both semantics-preserving by construction:

**(a) Take the window from the BASE table, once.** `max(snapshot_at)` needs no flatten.
Mirror the history view's `JOIN public.machines` so the anchor can never exceed what the
view is capable of emitting — this _removes_ leg 17's unverified "max is identical on base
and view" assumption instead of relying on it.

```sql
w AS (
  SELECT ba.t_anchor,
         ba.t_anchor - make_interval(days => p.win_days) AS t_start,
         p.floor_hours
  FROM p
  CROSS JOIN (
    -- BASE table: no JSONB flatten, no 4-tier resolver. Evaluated ONCE as an InitPlan.
    -- JOIN machines mirrors v_weimi_shelf_history_v3's INNER JOIN, so t_anchor is
    -- attainable by the view BY CONSTRUCTION (no cross-object max assumption).
    SELECT max(ds.snapshot_at) AS t_anchor
    FROM public.weimi_device_status ds
    JOIN public.machines m ON m.machine_id = ds.machine_id
  ) ba
),
```

**(b) Build `snaps` from the base table.** It only ever needed `(machine_id, snapshot_at)`.

```sql
snaps AS (
  SELECT DISTINCT ds.machine_id, ds.snapshot_at
  FROM public.weimi_device_status ds
  JOIN public.machines m ON m.machine_id = ds.machine_id
  CROSS JOIN w
  WHERE ds.snapshot_at >= w.t_start AND ds.snapshot_at <= w.t_anchor
    -- EQUIVALENCE GUARD: a snapshot whose door_statuses flattens to zero aisles does NOT
    -- appear in the history view, so it must not create an interval boundary here either.
    -- EXISTS short-circuits on the first aisle, so this is O(1) per snapshot, not a flatten.
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements(ds.door_statuses)      c(value),
           jsonb_array_elements(c.value -> 'layers')   l(value),
           jsonb_array_elements(l.value -> 'aisles')   a(value)
    )
),
```

`hist` (line 45) keeps reading the history view — it needs the canonical four-tier resolved
identity, and re-implementing that resolver is forbidden (leg-16 F5: lift verbatim, never
hand-roll; a hand-rolled resolver diverged on 17.1% of keys). With `t_start`/`t_anchor` now
InitPlan scalars, `snapshot_at` is in the `DISTINCT ON` key of both `snaps` and `deduped`
inside the view, so the predicate is **eligible** to push down past them.

Everything from `intervals` onward is unchanged.

## 3. Pre-flight assertions — run these BEFORE promoting to a migration

Each one is a **single cheap aggregate**. Run them one at a time. Never combine.

```sql
SET statement_timeout = '60000';  -- the SERVER must kill it, not just the client (RISK 43)
```

- **A1 — anchor equality.** Base-with-machines-join max == history-view max.
  Expect equal; if not, the view is dropping the newest snapshot and (a) is still correct
  but the diagnosis changes — stop and record.
- **A2 — snaps set-equality over the window.** `DISTINCT (machine_id, snapshot_at)` from the
  proposed base expression vs from the view, restricted to the same window. Expect
  **0 rows** in either direction of `EXCEPT`. ~1,500 rows/side; bounded and cheap.
  ⚠️ This is the assertion that validates the EXISTS guard. If it fails non-empty, the guard
  is wrong — do not proceed.
- **A3 — output equality.** Full old-vs-new output diff on **one machine**, then a second.
  `stock_hours`, `elapsed_hours`, all five `n_case_*`, `velocity_status`. Expect identical.
  Only after two clean machines, compare fleet-wide aggregates.

## 4. Verification protocol (binding — this is what caused the incident)

1. **One cheap aggregate per statement.** Never N subqueries in one statement: cost
   multiplies by N (RISK 44).
2. **Always scope to one machine first** (`WHERE machine_id = ...`).
3. **Always `SET statement_timeout` first.** A client timeout does not cancel the server
   query — that is exactly how prod stayed saturated for 30+ minutes (RISK 43).
4. If the DB is degraded on arrival, **kill the runaway first**:
   `SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE state='active' AND query
ILIKE '%v_shelf_instock_velocity_v3%' AND pid <> pg_backend_pid();`
   `pg_cancel_backend` first; `pg_terminate_backend` only if cancel fails.

## 5. If it is STILL slow — escalate, do not micro-optimise

A single flatten of 79k rows plus four LATERAL resolver lookups per row may still be too
slow for `engine_add_pod_v3`, which will query this per machine, per night.

**Escalate to Dara for a MATERIALIZED view refreshed nightly.** Article 14 explicitly
endorses "materialized views with explicit refresh semantics", so this is permitted **with
an ADR**. That is very likely the shape the engine actually needs. The natural split is to
materialise the expensive, slow-changing part — `v_weimi_shelf_history_v3` (the flatten +
resolver) — and leave the velocity arithmetic as a cheap regular view on top.

**Do not let a per-query 79k-row JSONB flatten reach `engine_add_pod_v3`.**

## 6. Constraints this proposal already satisfies

- Additive / forward-only; `CREATE OR REPLACE VIEW` on a view built this same day (Art 12).
- `WITH (security_invoker = true)` retained — Cody made this a condition (Art 2/3).
- Article 16 numerator untouched: still `v_shelf_sales_identity.units_30d`; raw
  `sales_history` still used only for intra-interval depletion timestamps (cases C/D).
- LAW 5 untouched: `out_of_canonical_scope` → NULL velocity, never a silent 0.
- No table, RLS, SECURITY DEFINER, protected entity, or live plan table touched.
- **Still owes Cody review before apply** (LAW 3) — this document is not a review.
